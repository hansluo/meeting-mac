import XCTest
@testable import MeetingCore

private final class MemoryCredentials: CredentialStore, @unchecked Sendable {
    var values: [String: Data] = [:]
    var events: [String] = []
    var failCreate = false
    var failDelete = false
    func create(_ secret: Data) throws -> String {
        events.append("create")
        if failCreate { throw CredentialStoreError(status: -1) }
        let reference = UUID().uuidString
        values[reference] = secret
        return reference
    }
    func read(reference: String) throws -> Data? {
        events.append("read")
        return values[reference]
    }
    func delete(reference: String) throws {
        events.append("delete")
        if failDelete { throw CredentialStoreError(status: -2) }
        values.removeValue(forKey: reference)
    }
}

private final class MemoryConfigurationFile: ConnectionConfigurationFile, @unchecked Sendable {
    var data: Data?
    var failWrite = false
    var onWrite: ((Data) -> Void)?
    func read() throws -> Data? { data }
    func writeAtomically(_ data: Data) throws {
        if failWrite { throw CocoaError(.fileWriteUnknown) }
        onWrite?(data)
        self.data = data
    }
}

@MainActor
final class ConnectionConfigurationTests: XCTestCase {
    private func profile(_ id: String = "llm") -> ProviderProfile {
        ProviderProfile(profileID: id, kind: .llm, backend: "openai", protocolName: "openai",
                        executionLocation: .onDevice, modelID: "qwen",
                        baseURL: URL(string: "http://127.0.0.1:1234/v1"))
    }
    private func setup() throws -> (ConnectionConfigurationStore, MemoryCredentials, MemoryConfigurationFile) {
        let keys = MemoryCredentials()
        let file = MemoryConfigurationFile()
        return (try ConnectionConfigurationStore(file: file, credentials: keys), keys, file)
    }
    func testMissingFileHasNoProfilesOrRoutesAndNoKeyAccess() async throws {
        let (store, keys, _) = try setup()
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.connections.isEmpty)
        XCTAssertTrue(snapshot.routes.isEmpty)
        XCTAssertTrue(keys.events.isEmpty)
    }
    func testReplacementCommitsReferenceOnlyAndRemovesOldKey() async throws {
        let (store, keys, file) = try setup()
        _ = try await store.save(profile(), credential: .replace(Data("old-secret".utf8)))
        let first = await store.snapshot().connections[0]
        _ = try await store.save(profile(), credential: .replace(Data("new-secret".utf8)))
        let second = await store.snapshot().connections[0]
        XCTAssertNotEqual(first.profile.credentialReference, second.profile.credentialReference)
        XCTAssertNil(keys.values[first.profile.credentialReference!])
        XCTAssertEqual(keys.values.count, 1)
        let json = String(decoding: file.data!, as: UTF8.self)
        XCTAssertFalse(json.contains("old-secret"))
        XCTAssertFalse(json.contains("new-secret"))
        XCTAssertTrue(json.contains(second.profile.credentialReference!))
    }
    func testKeyWriteFailurePreservesOldConfigurationAndKey() async throws {
        let (store, keys, file) = try setup()
        _ = try await store.save(profile(), credential: .replace(Data([1])))
        let before = await store.snapshot()
        let disk = file.data
        keys.failCreate = true
        do { _ = try await store.save(profile(), credential: .replace(Data([2]))); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionConfigurationError, .credentialWrite(status: -1)) }
        let after = await store.snapshot()
        XCTAssertEqual(before, after)
        XCTAssertEqual(disk, file.data)
        XCTAssertEqual(keys.values.count, 1)
    }
    func testConfigurationFailureRollsBackNewKeyAndRetainsOldState() async throws {
        let (store, keys, file) = try setup()
        _ = try await store.save(profile(), credential: .replace(Data([1])))
        let before = await store.snapshot()
        file.failWrite = true
        do { _ = try await store.save(profile(), credential: .replace(Data([2]))); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionConfigurationError, .configurationWrite(rollbackFailure: nil)) }
        let after = await store.snapshot()
        XCTAssertEqual(before, after)
        XCTAssertEqual(keys.values.count, 1)
    }
    func testRollbackFailureIsReportedAndOldConfigurationRemainsValid() async throws {
        let (store, keys, file) = try setup()
        _ = try await store.save(profile(), credential: .replace(Data([1])))
        let before = await store.snapshot()
        file.failWrite = true
        keys.failDelete = true
        do { _ = try await store.save(profile(), credential: .replace(Data([2]))); XCTFail() }
        catch {
            guard case .configurationWrite(let failure) = error as? ConnectionConfigurationError else {
                return XCTFail("expected rollback failure")
            }
            XCTAssertEqual(failure?.status, -2)
            let orphan = try XCTUnwrap(failure?.reference)
            XCTAssertNotEqual(orphan, before.connections[0].profile.credentialReference)
            XCTAssertEqual(keys.values[orphan], Data([2]))
        }
        let after = await store.snapshot()
        XCTAssertEqual(before, after)
        XCTAssertNotNil(keys.values[before.connections[0].profile.credentialReference!])
    }
    func testCleanupFailureReportsCommittedStateAndOrphanReference() async throws {
        let (store, keys, _) = try setup()
        _ = try await store.save(profile(), credential: .replace(Data([1])))
        let old = await store.snapshot().connections[0].profile.credentialReference!
        keys.failDelete = true
        let outcome = try await store.save(profile(), credential: .remove)
        XCTAssertEqual(outcome.cleanupFailure, CredentialCleanupFailure(reference: old, status: -2))
        let snapshot = await store.snapshot()
        XCTAssertNil(snapshot.connections[0].profile.credentialReference)
        XCTAssertNotNil(keys.values[old])
    }
    func testSharedCredentialIsRetainedUntilLastReferenceRemoved() async throws {
        let (store, keys, file) = try setup()
        _ = try await store.save(profile(), credential: .replace(Data([1])))
        var document = await store.snapshot()
        var shared = document.connections[0]
        shared.profile.profileID = "second"
        document.connections.append(shared)
        file.data = try JSONEncoder().encode(document)
        let reloaded = try ConnectionConfigurationStore(file: file, credentials: keys)
        _ = try await reloaded.save(profile(), credential: .remove)
        XCTAssertEqual(keys.values.count, 1)
        _ = try await reloaded.save(profile("second"), credential: .remove)
        XCTAssertTrue(keys.values.isEmpty)
    }
    func testRetainCannotSmuggleAReferenceAndNewNoKeyConnectionAllowed() async throws {
        let (store, keys, _) = try setup()
        var proposed = profile()
        proposed.credentialReference = UUID().uuidString
        _ = try await store.save(proposed, credential: .retain)
        let record = await store.snapshot().connections[0]
        XCTAssertNil(record.profile.credentialReference)
        XCTAssertTrue(keys.events.isEmpty)
    }
    func testProbeNeedsMatchingRevisionAndExplicitLocationEvidence() async throws {
        let (store, _, _) = try setup()
        _ = try await store.save(profile(), credential: .retain)
        let first = await store.snapshot().connections[0]
        try await store.recordProbe(profileID: "llm", revision: first.revision,
                                    capabilities: [.qa], locationEvidence: nil)
        var snapshot = await store.snapshot()
        XCTAssertFalse(snapshot.connections[0].profile.locationVerified)
        XCTAssertEqual(snapshot.connections[0].profile.verifiedCapabilities, [.qa])
        let evidence = ConnectionLocationEvidence(location: .onDevice, method: .controlledOfflineExecution, basis: "controlled offline execution")
        try await store.recordProbe(profileID: "llm", revision: first.revision,
                                    capabilities: [.qa], locationEvidence: evidence)
        var changed = profile()
        changed.modelID = "other"
        _ = try await store.save(changed, credential: .retain)
        snapshot = await store.snapshot()
        XCTAssertFalse(snapshot.connections[0].profile.locationVerified)
        XCTAssertTrue(snapshot.connections[0].profile.verifiedCapabilities.isEmpty)
        XCTAssertNil(snapshot.connections[0].locationEvidence)
        do {
            try await store.recordProbe(profileID: "llm", revision: first.revision,
                                        capabilities: [.qa], locationEvidence: evidence)
            XCTFail()
        } catch { XCTAssertEqual(error as? ConnectionConfigurationError, .staleRevision) }
    }
    func testEveryExecutionIdentityEditInvalidatesEvidence() async throws {
        let edits: [(inout ProviderProfile) -> Void] = [
            { $0.modelID = "other" }, { $0.baseURL = URL(string: "http://localhost:4321") },
            { $0.protocolName = "other" }, { $0.backend = "other" },
            { $0.runtimeVersion = "2" }, { $0.modelRevision = "2" },
            { $0.executionLocation = .cloud }, { $0.kind = .detector }
        ]
        for edit in edits {
            let (store, _, _) = try setup()
            _ = try await store.save(profile(), credential: .retain)
            let first = await store.snapshot().connections[0]
            try await store.recordProbe(profileID: "llm", revision: first.revision, capabilities: [.qa],
                locationEvidence: .init(location: .onDevice, method: .controlledOfflineExecution, basis: "offline probe"))
            var changed = profile()
            edit(&changed)
            changed.locationVerified = true
            changed.verifiedCapabilities = [.qa]
            _ = try await store.save(changed, credential: .retain)
            let saved = await store.snapshot().connections[0]
            XCTAssertFalse(saved.profile.locationVerified)
            XCTAssertTrue(saved.profile.verifiedCapabilities.isEmpty)
            XCTAssertNotEqual(first.revision, saved.revision)
        }
    }
    func testDuplicateProfilesRoutesAndUnsupportedSchemaFailLoading() async throws {
        let (store, keys, file) = try setup()
        _ = try await store.save(profile(), credential: .retain)
        let valid = await store.snapshot()
        var duplicate = valid
        duplicate.connections.append(duplicate.connections[0])
        file.data = try JSONEncoder().encode(duplicate)
        XCTAssertThrowsError(try ConnectionConfigurationStore(file: file, credentials: keys))
        duplicate = valid
        duplicate.routes = [TaskRoute(task: .qa), TaskRoute(task: .qa)]
        file.data = try JSONEncoder().encode(duplicate)
        XCTAssertThrowsError(try ConnectionConfigurationStore(file: file, credentials: keys))
        duplicate = valid
        duplicate.schemaVersion = 99
        file.data = try JSONEncoder().encode(duplicate)
        XCTAssertThrowsError(try ConnectionConfigurationStore(file: file, credentials: keys))
    }
    func testTemporaryProbeUsesOnlySuppliedSecretAndNeverReadsOrWritesStore() async throws {
        let (store, keys, file) = try setup()
        _ = try await store.save(profile(), credential: .retain)
        let before = file.data
        let context = TemporaryConnectionProbe(profile: profile(), credential: Data([42]))
        XCTAssertEqual(context.credential, Data([42]))
        XCTAssertFalse(context.profile.locationVerified)
        XCTAssertEqual(before, file.data)
        XCTAssertTrue(keys.events.isEmpty)
    }
    func testRoutesPersistExplicitlyAndRejectMissingProfile() async throws {
        let (store, _, _) = try setup()
        do { try await store.setRoutes([TaskRoute(task: .qa, profileID: "missing")]); XCTFail() }
        catch { XCTAssertEqual(error as? ConnectionConfigurationError, .invalidConfiguration) }
        _ = try await store.save(profile(), credential: .retain)
        try await store.setRoutes([TaskRoute(task: .qa, profileID: "llm", cloudAllowed: false)])
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.routes, [TaskRoute(task: .qa, profileID: "llm")])
    }
    func testUnknownPersistedFieldsAreRejectedRatherThanSilentlyDiscardingSecrets() async throws {
        let (store, keys, file) = try setup()
        _ = try await store.save(profile(), credential: .retain)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: file.data!) as? [String: Any])
        json["apiKey"] = "must-never-be-accepted"
        file.data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try ConnectionConfigurationStore(file: file, credentials: keys))
    }
    func testUserDeclarationCannotSupplyVerifiedLocationOnNewConnection() async throws {
        let (store, _, _) = try setup()
        var asserted = profile()
        asserted.locationVerified = true
        asserted.verifiedCapabilities = [.qa, .summary]
        _ = try await store.save(asserted, credential: .retain)
        let record = await store.snapshot().connections[0]
        XCTAssertFalse(record.profile.locationVerified)
        XCTAssertTrue(record.profile.verifiedCapabilities.isEmpty)
        XCTAssertNil(record.locationEvidence)
    }
    func testCredentialReplacementInvalidatesVerifiedConnection() async throws {
        let (store, _, _) = try setup()
        _ = try await store.save(profile(), credential: .replace(Data([1])))
        let original = await store.snapshot().connections[0]
        try await store.recordProbe(profileID: "llm", revision: original.revision, capabilities: [.qa],
                                   locationEvidence: .init(location: .onDevice, method: .controlledOfflineExecution, basis: "offline probe"))
        _ = try await store.save(profile(), credential: .replace(Data([2])))
        let updated = await store.snapshot().connections[0]
        XCTAssertNotEqual(original.revision, updated.revision)
        XCTAssertNil(updated.locationEvidence)
        XCTAssertFalse(updated.profile.locationVerified)
        XCTAssertTrue(updated.profile.verifiedCapabilities.isEmpty)
    }
    func testAtomicFileRoundTripAndReloadPreserveExplicitEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = AtomicConnectionConfigurationFile(url: directory.appendingPathComponent("connections.json"))
        let keys = MemoryCredentials()
        let store = try ConnectionConfigurationStore(file: file, credentials: keys)
        _ = try await store.save(profile(), credential: .retain)
        let record = await store.snapshot().connections[0]
        try await store.recordProbe(profileID: "llm", revision: record.revision, capabilities: [.qa],
                                   locationEvidence: .init(location: .onDevice, method: .controlledOfflineExecution, basis: "offline probe"))
        let loaded = try ConnectionConfigurationStore(file: file, credentials: keys)
        let expected = await store.snapshot()
        let actual = await loaded.snapshot()
        XCTAssertEqual(actual, expected)
    }
    func testReplacementKeyExistsBeforeCommitAndOldKeyDeletedOnlyAfterCommit() async throws {
        let (store, keys, file) = try setup()
        _ = try await store.save(profile(), credential: .replace(Data([1])))
        let old = await store.snapshot().connections[0].profile.credentialReference!
        var observed = false
        file.onWrite = { data in
            let document = try! JSONDecoder().decode(ConnectionConfiguration.self, from: data)
            let new = document.connections[0].profile.credentialReference!
            XCTAssertNotEqual(new, old)
            XCTAssertEqual(keys.values[new], Data([2]))
            XCTAssertEqual(keys.values[old], Data([1]))
            observed = true
        }
        _ = try await store.save(profile(), credential: .replace(Data([2])))
        XCTAssertTrue(observed)
        XCTAssertNil(keys.values[old])
    }
    func testCancelledSaveDoesNotWriteKeyOrConfiguration() async throws {
        let (store, keys, file) = try setup()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.save(profile(), credential: .replace(Data([1])))
        }
        do { _ = try await task.value; XCTFail() } catch is CancellationError {} catch { XCTFail("unexpected cancellation result") }
        XCTAssertNil(file.data)
        XCTAssertTrue(keys.events.isEmpty)
    }
    func testConcurrentEditsAreSerializedWithoutLosingProfiles() async throws {
        let (store, keys, _) = try setup()
        let profiles = (0..<12).map { profile("llm-\($0)") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for candidate in profiles {
                group.addTask { _ = try await store.save(candidate, credential: .replace(Data([1]))) }
            }
            try await group.waitForAll()
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.connections.count, profiles.count)
        XCTAssertEqual(keys.values.count, profiles.count)
    }
    func testRejectsCredentialBearingEndpointWithoutWritingKey() async throws {
        for endpoint in ["https://user:password@example.com/v1", "https://example.com/v1?api_key=secret"] {
            let (store, keys, file) = try setup()
            var candidate = profile()
            candidate.baseURL = URL(string: endpoint)
            do { _ = try await store.save(candidate, credential: .replace(Data([1]))); XCTFail() }
            catch { XCTAssertEqual(error as? ConnectionConfigurationError, .invalidConfiguration) }
            XCTAssertNil(file.data)
            XCTAssertTrue(keys.events.isEmpty)
        }
    }

    func testLocationEvidenceRetainsMethodDateAndConfigurationRevision() async throws {
        let (store, _, _) = try setup()
        _ = try await store.save(profile(), credential: .retain)
        let record = await store.snapshot().connections[0]
        let observed = Date(timeIntervalSince1970: 1000)
        let evidence = ConnectionLocationEvidence(location: .onDevice, method: .controlledOfflineExecution,
            basis: "owned runtime offline execution", observedAt: observed)
        try await store.recordProbe(profileID: "llm", revision: record.revision, capabilities: [.qa], locationEvidence: evidence)
        let saved = await store.snapshot().connections[0]
        XCTAssertEqual(saved.locationEvidence?.method, .controlledOfflineExecution)
        XCTAssertEqual(saved.locationEvidence?.observedAt, observed)
        XCTAssertEqual(saved.revision, record.revision)
    }

}
