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
        let matches = profiles.filter { $0.profileID == profileID }
        guard !matches.isEmpty else {
            throw RouteError.profileNotFound(profileID)
        }
        guard matches.count == 1 else { throw RouteError.ambiguousProfile(profileID) }
        let profile = matches[0]
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
