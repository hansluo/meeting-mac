import XCTest
@testable import MeetingCore

final class RouteResolverTests: XCTestCase {
    private func profile(
        id: String = "selected", kind: ModelKind = .asr,
        location: ExecutionLocation = .onDevice, verified: Bool = true,
        modelID: String? = "model", capabilities: Set<TaskRole> = [.realtimeASR]
    ) -> ProviderProfile {
        ProviderProfile(profileID: id, kind: kind, executionLocation: location,
                        modelID: modelID, locationVerified: verified,
                        verifiedCapabilities: capabilities)
    }

    private func assertError(
        _ expected: RouteError, task: TaskRole = .realtimeASR,
        route: TaskRoute? = nil, profiles: [ProviderProfile],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try RouteResolver.resolve(
            task: task, route: route ?? TaskRoute(task: task, profileID: "selected"),
            profiles: profiles
        ), file: file, line: line) { error in
            XCTAssertEqual(error as? RouteError, expected, file: file, line: line)
        }
    }

    func testResolvesExplicitVerifiedLocalProfile() throws {
        let selected = profile()
        let resolved = try RouteResolver.resolve(
            task: .realtimeASR, route: TaskRoute(task: .realtimeASR, profileID: "selected"),
            profiles: [profile(id: "first"), selected]
        )
        XCTAssertEqual(resolved, selected)
    }

    func testMissingSelectionNeverFallsBackToFirstProfile() {
        assertError(.profileNotSelected, route: TaskRoute(task: .realtimeASR), profiles: [profile()])
    }

    func testMissingSelectedProfileNeverFallsBack() {
        assertError(.profileNotFound("selected"), profiles: [profile(id: "first")])
    }

    func testLocalOnlyRejectsCloudLANAndUnverifiedLocations() {
        for location in [ExecutionLocation.cloud, .lan, .unverified] {
            assertError(.locationForbidden(location), profiles: [profile(location: location)])
        }
    }

    func testClaimedLocalLocationRequiresVerification() {
        assertError(.locationNotVerified, profiles: [profile(verified: false)])
    }

    func testASRRejectsLLMEvenWithClaimedASRCapability() {
        assertError(.wrongModelKind(expected: [.asr], actual: .llm), profiles: [profile(kind: .llm)])
    }

    func testModelIDMustBeExplicitAndNonempty() {
        for modelID in [nil, "", " \n "] as [String?] {
            assertError(.modelNotSelected, profiles: [profile(modelID: modelID)])
        }
    }

    func testTaskCapabilityMustBeVerifiedIndependently() {
        assertError(.capabilityNotVerified(.realtimeASR), profiles: [profile(capabilities: [.fileASR])])
    }

    func testCloudPermissionIsScopedToOneTask() throws {
        let cloud = profile(kind: .llm, location: .cloud, capabilities: [.summary, .qa])
        XCTAssertEqual(try RouteResolver.resolve(
            task: .summary, route: TaskRoute(task: .summary, profileID: "selected", cloudAllowed: true),
            profiles: [cloud]
        ), cloud)
        assertError(.locationForbidden(.cloud), task: .qa, profiles: [cloud])
        assertError(.routeTaskMismatch, task: .qa,
                    route: TaskRoute(task: .summary, profileID: "selected", cloudAllowed: true), profiles: [cloud])
        assertError(.locationForbidden(.cloud), profiles: [profile(location: .cloud)])
    }

    func testQuestionDetectionAllowsDetectorOrIndependentlyVerifiedLLM() throws {
        for kind in [ModelKind.detector, .llm] {
            let selected = profile(kind: kind, capabilities: [.questionDetection])
            XCTAssertEqual(try RouteResolver.resolve(
                task: .questionDetection,
                route: TaskRoute(task: .questionDetection, profileID: "selected"), profiles: [selected]
            ), selected)
        }
        assertError(.capabilityNotVerified(.questionDetection), task: .questionDetection,
                    profiles: [profile(kind: .llm, capabilities: [.qa])])
    }

    func testCloudPermissionDoesNotPermitLANOrUnverifiedLocation() {
        for location in [ExecutionLocation.lan, .unverified] {
            assertError(.locationForbidden(location),
                        route: TaskRoute(task: .realtimeASR, profileID: "selected", cloudAllowed: true),
                        profiles: [profile(location: location)])
        }
        assertError(.locationNotVerified,
                    route: TaskRoute(task: .realtimeASR, profileID: "selected", cloudAllowed: true),
                    profiles: [profile(location: .cloud, verified: false)])
    }

    func testConfigurationRoundTripsWithoutLosingVerificationOrTaskPolicy() throws {
        let selected = profile()
        XCTAssertEqual(try JSONDecoder().decode(ProviderProfile.self, from: JSONEncoder().encode(selected)), selected)
        let route = TaskRoute(task: .summary, profileID: "selected", cloudAllowed: true)
        XCTAssertEqual(try JSONDecoder().decode(TaskRoute.self, from: JSONEncoder().encode(route)), route)
    }
}
