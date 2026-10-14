import Foundation

public enum ModelKind: String, Codable, Sendable, CaseIterable {
    case asr, llm, embedding, detector
}

public enum ExecutionLocation: String, Codable, Sendable, CaseIterable {
    case onDevice = "on_device"
    case lan, cloud, unverified
}

public enum TaskRole: String, Codable, Sendable, CaseIterable {
    case realtimeASR = "realtime_asr"
    case fileASR = "file_asr"
    case retranscription, qa, summary
    case noteEnhancement = "notes_enhancement"
    case voiceInputASR = "voice_input_asr"
    case voiceInputCorrection = "voice_input_correction"
    case embedding
    case questionDetection = "question_detection"
}

public struct ProviderProfile: Codable, Sendable, Equatable {
    public var profileID: String
    public var kind: ModelKind
    public var backend: String
    public var protocolName: String
    public var executionLocation: ExecutionLocation
    public var modelID: String?
    public var modelRevision: String?
    public var runtimeVersion: String?
    /// Evidence confirms the configured execution classification, not merely a localhost URL.
    public var locationVerified: Bool
    /// Tasks validated against this specific model and runtime configuration.
    public var verifiedCapabilities: Set<TaskRole>
    public var baseURL: URL?
    /// Keychain reference only; never credential material.
    public var credentialReference: String?

    public init(profileID: String, kind: ModelKind, backend: String = "",
                protocolName: String = "", executionLocation: ExecutionLocation,
                modelID: String?, modelRevision: String? = nil, runtimeVersion: String? = nil,
                locationVerified: Bool = false, verifiedCapabilities: Set<TaskRole> = [],
                baseURL: URL? = nil, credentialReference: String? = nil) {
        self.profileID = profileID
        self.kind = kind
        self.backend = backend
        self.protocolName = protocolName
        self.executionLocation = executionLocation
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.runtimeVersion = runtimeVersion
        self.locationVerified = locationVerified
        self.verifiedCapabilities = verifiedCapabilities
        self.baseURL = baseURL
        self.credentialReference = credentialReference
    }
}

public struct TaskRoute: Codable, Sendable, Equatable {
    public var task: TaskRole
    public var profileID: String?
    public var cloudAllowed: Bool

    public init(task: TaskRole, profileID: String? = nil, cloudAllowed: Bool = false) {
        self.task = task
        self.profileID = profileID
        self.cloudAllowed = cloudAllowed
    }
}

public enum RouteError: Error, Sendable, Equatable {
    case routeTaskMismatch
    case profileNotSelected
    case profileNotFound(String)
    case modelNotSelected
    case locationForbidden(ExecutionLocation)
    case locationNotVerified
    case wrongModelKind(expected: Set<ModelKind>, actual: ModelKind)
    case capabilityNotVerified(TaskRole)
}
