import Foundation

/// A write must replace the complete file atomically or throw without replacing it.
public protocol ConnectionConfigurationFile: Sendable {
    func read() throws -> Data?
    func writeAtomically(_ data: Data) throws
}
public enum ConnectionLocationVerificationMethod: String, Codable, Sendable {
    case controlledOfflineExecution
    case runtimeAttestation
}
/// Evidence from an execution verifier, distinct from the user's configured classification.
/// Its containing ConnectionRecord binds this evidence to an exact configuration revision.
public struct ConnectionLocationEvidence: Codable, Sendable, Equatable {
    public var location: ExecutionLocation
    public var method: ConnectionLocationVerificationMethod
    public var basis: String
    public var observedAt: Date
    public init(location: ExecutionLocation, method: ConnectionLocationVerificationMethod, basis: String, observedAt: Date = Date()) {
        self.location = location; self.method = method; self.basis = basis; self.observedAt = observedAt
    }
}
public struct ConnectionRecord: Codable, Sendable, Equatable {
    public var profile: ProviderProfile
    public var revision: UUID
    public var locationEvidence: ConnectionLocationEvidence?
}
public struct ConnectionConfiguration: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var connections: [ConnectionRecord] = []
    public var routes: [TaskRoute] = []
    public init() {}
}
public enum CredentialIntent: Sendable {
    case retain, replace(Data), remove
}
public struct CredentialCleanupFailure: Sendable, Equatable {
    public let reference: String
    public let status: Int32
    public init(reference: String, status: Int32) { self.reference = reference; self.status = status }
}
public struct ConnectionSaveOutcome: Sendable {
    public let record: ConnectionRecord
    public let cleanupFailure: CredentialCleanupFailure?
}
public enum ConnectionConfigurationError: Error, Sendable, Equatable {
    case invalidConfiguration, configurationRead, staleRevision, profileNotFound
    case credentialWrite(status: Int32)
    case configurationWrite(rollbackFailure: CredentialCleanupFailure?)
}
/// In-memory test context only. Creating it has no persistent side effects and grants no readiness.
public struct TemporaryConnectionProbe: Sendable {
    public let profile: ProviderProfile
    public let credential: Data?
    public init(profile: ProviderProfile, credential: Data?) {
        var candidate = profile
        candidate.locationVerified = false
        candidate.verifiedCapabilities = []
        candidate.credentialReference = nil
        self.profile = candidate; self.credential = credential
    }
}
/// An explicit path is required; there is no implicit default model, route, or cloud policy.
public struct AtomicConnectionConfigurationFile: ConnectionConfigurationFile {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func read() throws -> Data? {
        guard url.isFileURL else { throw ConnectionConfigurationError.invalidConfiguration }
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    public func writeAtomically(_ data: Data) throws {
        guard url.isFileURL else { throw ConnectionConfigurationError.invalidConfiguration }
        try data.write(to: url, options: .atomic)
    }
}

/// Own one store per configuration file. All credential and file operations complete
/// synchronously within each actor transaction, so edits cannot interleave.
/// A committed save can report failed old-key cleanup without misreporting the save as failed.
public actor ConnectionConfigurationStore {
    private let file: any ConnectionConfigurationFile
    private let credentials: any CredentialStore
    private var configuration: ConnectionConfiguration

    public init(file: any ConnectionConfigurationFile, credentials: any CredentialStore) throws {
        self.file = file
        self.credentials = credentials
        let data: Data?
        do { data = try file.read() }
        catch { throw ConnectionConfigurationError.configurationRead }
        if let data {
            do {
                try Self.validateSchema(data)
                configuration = try JSONDecoder().decode(ConnectionConfiguration.self, from: data)
            }
            catch { throw ConnectionConfigurationError.invalidConfiguration }
        } else { configuration = ConnectionConfiguration() }
        try Self.validate(configuration)
    }
    public func snapshot() -> ConnectionConfiguration { configuration }

    public func save(_ profile: ProviderProfile, credential: CredentialIntent) throws -> ConnectionSaveOutcome {
        try Task.checkCancellation()
        let old = configuration.connections.first { $0.profile.profileID == profile.profileID }
        var candidate = profile
        // References and verification are exclusively managed here, never imported from a settings form.
        candidate.credentialReference = old?.profile.credentialReference
        candidate.locationVerified = false
        candidate.verifiedCapabilities = []
        var next = configuration
        let index = next.connections.firstIndex { $0.profile.profileID == profile.profileID }
        let placeholder = ConnectionRecord(profile: candidate, revision: UUID(), locationEvidence: nil)
        if let index { next.connections[index] = placeholder } else { next.connections.append(placeholder) }
        try Self.validate(next) // Validate before touching credentials.
        var createdReference: String?
        switch credential {
        case .retain: break
        case .remove: candidate.credentialReference = nil
        case .replace(let secret):
            do { createdReference = try credentials.create(secret) }
            catch { throw ConnectionConfigurationError.credentialWrite(status: Self.status(error)) }
            candidate.credentialReference = createdReference
        }
        var record = ConnectionRecord(profile: candidate, revision: UUID(), locationEvidence: nil)
        if let old, Self.sameExecutionIdentity(old.profile, candidate) {
            record = old
            // Keep the full previous verified state only when execution identity is unchanged.
        }
        if let index { next.connections[index] = record } else { next.connections[next.connections.count - 1] = record }
        do {
            try Self.validate(next)
            try Task.checkCancellation()
            try persist(next)
        } catch {
            var rollbackFailure: CredentialCleanupFailure?
            if let createdReference {
                do { try credentials.delete(reference: createdReference) }
                catch { rollbackFailure = CredentialCleanupFailure(reference: createdReference, status: Self.status(error)) }
            }
            throw ConnectionConfigurationError.configurationWrite(rollbackFailure: rollbackFailure)
        }
        var cleanupFailure: CredentialCleanupFailure?
        if let reference = old?.profile.credentialReference,
           !next.connections.contains(where: { $0.profile.credentialReference == reference }) {
            do { try credentials.delete(reference: reference) }
            catch { cleanupFailure = CredentialCleanupFailure(reference: reference, status: Self.status(error)) }
        }
        return ConnectionSaveOutcome(record: record, cleanupFailure: cleanupFailure)
    }

    public func setRoutes(_ routes: [TaskRoute]) throws {
        var next = configuration
        next.routes = routes
        try Self.validate(next)
        try Task.checkCancellation()
        do { try persist(next) }
        catch { throw ConnectionConfigurationError.configurationWrite(rollbackFailure: nil) }
    }

    /// Call only after an actual successful capability probe. Discovery is not a probe.
    /// Location evidence must come from an independent execution check; configured classification,
    /// a user's declaration, and loopback reachability do not supply this evidence.
    public func recordProbe(profileID: String, revision: UUID, capabilities: Set<TaskRole>,
                            locationEvidence: ConnectionLocationEvidence?) throws {
        guard let index = configuration.connections.firstIndex(where: { $0.profile.profileID == profileID }) else {
            throw ConnectionConfigurationError.profileNotFound
        }
        guard configuration.connections[index].revision == revision else {
            throw ConnectionConfigurationError.staleRevision
        }
        var next = configuration
        next.connections[index].profile.verifiedCapabilities = capabilities
        next.connections[index].profile.locationVerified = locationEvidence != nil
        next.connections[index].locationEvidence = locationEvidence
        try Self.validate(next)
        try Task.checkCancellation()
        do { try persist(next) }
        catch { throw ConnectionConfigurationError.configurationWrite(rollbackFailure: nil) }
    }

    private func persist(_ next: ConnectionConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        try file.writeAtomically(data)
        configuration = next
    }
    private static func status(_ error: any Error) -> Int32 {
        (error as? CredentialStoreError)?.status ?? -1
    }
    private static func sameExecutionIdentity(_ lhs: ProviderProfile, _ rhs: ProviderProfile) -> Bool {
        var left = lhs
        var right = rhs
        left.locationVerified = false; right.locationVerified = false
        left.verifiedCapabilities = []; right.verifiedCapabilities = []
        return left == right
    }
    private static func validateSchema(_ data: Data) throws {
        func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
            guard let object = value as? [String: Any], Set(object.keys).isSubset(of: keys) else {
                throw ConnectionConfigurationError.invalidConfiguration
            }
            return object
        }
        let root = try object(JSONSerialization.jsonObject(with: data), keys: ["schemaVersion", "connections", "routes"])
        guard let connections = root["connections"] as? [Any], let routes = root["routes"] as? [Any] else {
            throw ConnectionConfigurationError.invalidConfiguration
        }
        for item in connections {
            let record = try object(item, keys: ["profile", "revision", "locationEvidence"])
            guard let profile = record["profile"] else { throw ConnectionConfigurationError.invalidConfiguration }
            _ = try object(profile, keys: ["profileID", "kind", "backend", "protocolName", "executionLocation",
                "modelID", "modelRevision", "runtimeVersion", "locationVerified", "verifiedCapabilities",
                "baseURL", "credentialReference"])
            if let evidence = record["locationEvidence"], !(evidence is NSNull) {
                _ = try object(evidence, keys: ["location", "method", "basis", "observedAt"])
            }
        }
        for item in routes { _ = try object(item, keys: ["task", "profileID", "cloudAllowed"]) }
    }
    private static func validate(_ value: ConnectionConfiguration) throws {
        guard value.schemaVersion == 1,
              Set(value.connections.map { $0.profile.profileID }).count == value.connections.count,
              Set(value.routes.map { $0.task }).count == value.routes.count else {
            throw ConnectionConfigurationError.invalidConfiguration
        }
        let ids = Set(value.connections.map { $0.profile.profileID })
        for record in value.connections {
            let profile = record.profile
            guard !profile.profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConnectionConfigurationError.invalidConfiguration
            }
            if let reference = profile.credentialReference {
                guard let uuid = UUID(uuidString: reference), uuid.uuidString == reference else {
                    throw ConnectionConfigurationError.invalidConfiguration
                }
            }
            if let url = profile.baseURL {
                guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      ["http", "https"].contains(components.scheme), components.host != nil,
                      components.user == nil, components.password == nil,
                      components.query == nil, components.fragment == nil else {
                    throw ConnectionConfigurationError.invalidConfiguration
                }
            }
            guard profile.locationVerified == (record.locationEvidence != nil) else {
                throw ConnectionConfigurationError.invalidConfiguration
            }
            if let evidence = record.locationEvidence {
                guard evidence.location != .unverified, evidence.location == profile.executionLocation,
                      !evidence.basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConnectionConfigurationError.invalidConfiguration
                }
            }
        }
        for route in value.routes {
            guard route.profileID == nil || ids.contains(route.profileID!) else {
                throw ConnectionConfigurationError.invalidConfiguration
            }
        }
    }
}
