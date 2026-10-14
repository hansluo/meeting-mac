import Foundation

/// Resolves only the explicitly selected profile. Does not probe, execute, or fall back.
public enum RouteResolver {
    public static func resolve(task: TaskRole, route: TaskRoute,
                               profiles: [ProviderProfile]) throws -> ProviderProfile {
        guard route.task == task else { throw RouteError.routeTaskMismatch }
        guard let profileID = route.profileID,
              !profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RouteError.profileNotSelected
        }
        guard let profile = profiles.first(where: { $0.profileID == profileID }) else {
            throw RouteError.profileNotFound(profileID)
        }
        guard let modelID = profile.modelID,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RouteError.modelNotSelected
        }
        let location = profile.executionLocation
        guard location == .onDevice || (location == .cloud && route.cloudAllowed) else {
            throw RouteError.locationForbidden(location)
        }
        guard profile.locationVerified else { throw RouteError.locationNotVerified }

        let expectedKinds: Set<ModelKind>
        switch task {
        case .realtimeASR, .fileASR, .retranscription, .voiceInputASR:
            expectedKinds = [.asr]
        case .qa, .summary, .noteEnhancement, .voiceInputCorrection:
            expectedKinds = [.llm]
        case .embedding:
            expectedKinds = [.embedding]
        case .questionDetection:
            expectedKinds = [.detector, .llm]
        }
        guard expectedKinds.contains(profile.kind) else {
            throw RouteError.wrongModelKind(expected: expectedKinds, actual: profile.kind)
        }
        guard profile.verifiedCapabilities.contains(task) else {
            throw RouteError.capabilityNotVerified(task)
        }
        return profile
    }
}
