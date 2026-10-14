import XCTest
import Foundation
import Darwin
@testable import MeetingCore

final class ChatClientTests: XCTestCase, @unchecked Sendable {
    func testEndpointPathsAndValidation() throws {
        for (base, expected) in [("http://localhost:123", "/v1/chat/completions"),
                                 ("https://example.com/v1/", "/v1/chat/completions"),
                                 ("http://localhost/prefix", "/prefix/chat/completions")] {
            XCTAssertEqual(try ChatEndpoint(baseURL: URL(string: base)!).chatURL.path, expected)
        }
        XCTAssertEqual(try ChatEndpoint(baseURL: URL(string: "http://localhost/prefix")!, apiPrefix: "/custom/v2").chatURL.path, "/prefix/custom/v2/chat/completions")
        XCTAssertEqual(try ChatEndpoint(baseURL: URL(string: "http://localhost/v1")!, apiPrefix: "/v1").chatURL.path, "/v1/chat/completions")
        XCTAssertEqual(try ChatEndpoint(baseURL: URL(string: "http://localhost")!, apiPrefix: "").chatURL.path, "/chat/completions")
        for base in ["ftp://localhost", "http://user:pass@localhost", "http://localhost?x=y", "http://localhost#fragment"] {
            XCTAssertThrowsError(try ChatEndpoint(baseURL: URL(string: base)!))
        }
    }
}

private enum ChatServerError: Error { case startupTimedOut }

private final class ChatServer {
    let process: Process
    let baseURL: URL
    init(process: Process = Process(), startupTimeout: TimeInterval = 5, startupDelay: TimeInterval = 0) throws {
        self.process = process
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/chat_server.py")
        process.arguments = ["python3", fixture.path, "--startup-delay", String(startupDelay)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? output.fileHandleForWriting.close()
        defer { try? output.fileHandleForReading.close() }
        do {
            let data = try Self.readStartupLine(from: output.fileHandleForReading, timeout: startupTimeout)
            guard let line = String(data: data, encoding: .utf8), let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            baseURL = URL(string: "http://127.0.0.1:\(port)")!
        } catch {
            Self.stopProcess(process)
            throw error
        }
    }
    private static func readStartupLine(from handle: FileHandle, timeout: TimeInterval) throws -> Data {
        guard timeout.isFinite, timeout > 0 else { throw ChatServerError.startupTimedOut }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        while data.count < 128 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ChatServerError.startupTimedOut }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min(ceil(remaining * 1000), Double(Int32.max)))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready == 0 { throw ChatServerError.startupTimedOut }
            if ready < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            var byte: UInt8 = 0
            let count = Darwin.read(handle.fileDescriptor, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { throw CocoaError(.fileReadCorruptFile) }
            if byte == 10 { return data }
            data.append(byte)
        }
        throw CocoaError(.fileReadCorruptFile)
    }
    private static func stopProcess(_ process: Process) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // Foundation reaps the child; avoid waitUntilExit's run-loop dependency in async XCTest.
        for _ in 0..<100 where process.isRunning { usleep(10_000) }
        XCTAssertFalse(process.isRunning, "Fixture must exit")
    }
    func stop() { Self.stopProcess(process) }
    func url(_ prefix: String = "") -> URL { baseURL.appendingPathComponent(prefix) }
    func records() async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: url("records"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
}

extension ChatClientTests {
    private func profile(_ baseURL: URL, id: String = "selected", model: String = "chosen", location: ExecutionLocation = .onDevice) -> ProviderProfile {
        ProviderProfile(profileID: id, kind: .llm, executionLocation: location, modelID: model,
                        locationVerified: true, verifiedCapabilities: [.summary], baseURL: baseURL)
    }
    private var route: TaskRoute { TaskRoute(task: .summary, profileID: "selected") }
    private var messages: [ChatMessage] { [ChatMessage(role: .system, content: "Be precise"), ChatMessage(role: .user, content: "Summarize") ] }
    private func expectError(_ expected: ChatClientError, operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected error", file: file, line: line) }
        catch { XCTAssertEqual(error as? ChatClientError, expected, file: file, line: line)
            XCTAssertFalse(String(describing: error).contains("secret"), file: file, line: line)
        }
    }

    func testGenerationUsesSelectedModelBearerAndOnlyStandardFields() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient(timeout: 5)
        let result = try await client.generate(task: .summary, route: route,
            profiles: [profile(server.baseURL, id: "first", model: "wrong"), profile(server.url("custom/prefix"))],
            messages: messages, credential: "test-key", maxTokens: 123, temperature: 0.2)
        XCTAssertEqual(result.content, "answer")
        XCTAssertEqual(result.finishReason, "stop")
        XCTAssertEqual(result.model, "chosen")
        XCTAssertEqual(result.usage?.totalTokens, 5)
        let records = try await server.records()
        let request = try XCTUnwrap(records.first)
        XCTAssertEqual(request["path"] as? String, "/custom/prefix/chat/completions")
        XCTAssertEqual(request["method"] as? String, "POST")
        let headers = try XCTUnwrap(request["headers"] as? [String: String])
        XCTAssertEqual(headers["Authorization"], "Bearer test-key")
        let body = try XCTUnwrap(request["body"] as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "messages", "stream", "max_tokens", "temperature"])
        XCTAssertEqual(body["model"] as? String, "chosen")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["max_tokens"] as? Int, 123)
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
        XCTAssertEqual(body["messages"] as? [[String: String]], [["role": "system", "content": "Be precise"], ["role": "user", "content": "Summarize"]])
    }

    func testRootAndV1NeverRepeatV1AndOptionalFieldsOmitted() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient()
        for base in [server.baseURL, server.url("v1")] {
            _ = try await client.generate(task: .summary, route: route, profiles: [profile(base)], messages: messages)
        }
        for record in try await server.records() {
            XCTAssertEqual(record["path"] as? String, "/v1/chat/completions")
            XCTAssertEqual(Set((record["body"] as? [String: Any] ?? [:]).keys), ["model", "messages", "stream"])
            XCTAssertNil((record["headers"] as? [String: String])?["Authorization"])
        }
    }

    func testDiscoveryFormatsAreSeparatelySelectable() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient()
        let openAI = try await client.discover(endpoint: ChatEndpoint(baseURL: server.baseURL), format: .openAI)
        let ollama = try await client.discover(endpoint: ChatEndpoint(baseURL: server.baseURL), format: .ollama)
        XCTAssertEqual(openAI, ["chosen", "other"])
        XCTAssertEqual(ollama, ["qwen:local", "other"])
        let records = try await server.records()
        XCTAssertEqual(records.compactMap { $0["path"] as? String }, ["/v1/models", "/api/tags"])
    }

    func test404DiscoveryDoesNotBlockManualGeneration() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient()
        try await expectDiscovery404(client, server)
        let result = try await client.generate(task: .summary, route: route, profiles: [profile(server.url("manual"), model: "manual-model")], messages: messages)
        XCTAssertEqual(result.content, "answer")
        let records = try await server.records()
        XCTAssertEqual((records.last?["body"] as? [String: Any])?["model"] as? String, "manual-model")
    }
    private func expectDiscovery404(_ client: ChatClient, _ server: ChatServer) async throws {
        await expectError(.httpStatus(404)) {
            _ = try await client.discover(endpoint: ChatEndpoint(baseURL: server.url("manual")), format: .openAI)
        }
    }

    func testHTTPStatusesAndMalformedResponsesAreTypedAndRedacted() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient()
        for status in [401, 429, 500] {
            await expectError(.httpStatus(status)) {
                _ = try await client.generate(task: .summary, route: self.route, profiles: [self.profile(server.url(String(status)))], messages: self.messages, credential: "secret-key")
            }
        }
        for mode in ["malformed", "empty", "missing-content", "wrong-role", "null-content", "blank-content", "malformed-usage"] {
            await expectError(.invalidResponse) {
                _ = try await client.generate(task: .summary, route: self.route, profiles: [self.profile(server.url(mode))], messages: self.messages)
            }
        }
    }

    func testRedirectIsNeverFollowed() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient()
        await expectError(.redirectRejected) {
            _ = try await client.generate(task: .summary, route: self.route, profiles: [self.profile(server.url("redirect"))], messages: self.messages, credential: "secret-key")
        }
        let records = try await server.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?["path"] as? String, "/redirect/chat/completions")
    }

    func testInvalidRoutesAndExternalLocalEndpointsMakeNoRequest() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient()
        do {
            _ = try await client.generate(task: .summary, route: TaskRoute(task: .summary, profileID: "missing"), profiles: [profile(server.baseURL)], messages: messages)
            XCTFail("Expected route rejection")
        } catch { XCTAssertEqual(error as? RouteError, .profileNotFound("missing")) }
        do {
            _ = try await client.generate(task: .qa, route: route, profiles: [profile(server.baseURL)], messages: messages)
            XCTFail("Expected route rejection")
        } catch { XCTAssertEqual(error as? RouteError, .routeTaskMismatch) }
        for url in ["http://example.com", "http://192.168.1.2", "http://127.0.0.2", "http://localhost.example.com"] {
            await expectError(.onDeviceEndpointRequired) {
                _ = try await client.generate(task: .summary, route: self.route, profiles: [self.profile(URL(string: url)!)], messages: self.messages)
            }
        }
        let records = try await server.records()
        XCTAssertTrue(records.isEmpty)
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            XCTAssertTrue(try ChatEndpoint(baseURL: URL(string: "http://\(host)")!).isLoopback)
        }
    }

    func testCancellationIsTyped() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient(timeout: 5)
        let selected = profile(server.url("slow")), messages = self.messages, route = self.route
        let task = Task { try await client.generate(task: .summary, route: route, profiles: [selected], messages: messages) }
        for _ in 0..<100 {
            if !(try await server.records()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await expectError(.cancelled) { _ = try await task.value }
    }

    func testBoundedTimeoutAndParameterValidation() async throws {
        for timeout in [0.0, -1, .infinity, .nan, 301] { XCTAssertThrowsError(try ChatClient(timeout: timeout)) }
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient(timeout: 0.1)
        await expectError(.transport(code: URLError.timedOut.rawValue)) {
            _ = try await client.generate(task: .summary, route: self.route, profiles: [self.profile(server.url("slow"))], messages: self.messages)
        }
        await expectError(.invalidParameters) {
            _ = try await client.generate(task: .summary, route: self.route, profiles: [self.profile(server.baseURL)], messages: self.messages, maxTokens: -1)
        }
    }
}

extension ChatClientTests {
    func testMissingOptionalResponseMetadataRemainsAbsent() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let result = try await ChatClient().generate(task: .summary, route: route,
            profiles: [profile(server.url("minimal"))], messages: messages)
        XCTAssertEqual(result.content, "answer")
        XCTAssertNil(result.model)
        XCTAssertNil(result.finishReason)
        XCTAssertNil(result.usage)
    }

    func testDiscoveryRejectsWrongFormatAndMalformedData() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient()
        for mode in ["malformed", "empty", "bad-models"] {
            await expectError(.invalidResponse) {
                _ = try await client.discover(endpoint: ChatEndpoint(baseURL: server.url(mode)), format: .openAI)
            }
            await expectError(.invalidResponse) {
                _ = try await client.discover(endpoint: ChatEndpoint(baseURL: server.url(mode)), format: .ollama)
            }
        }
    }
}

extension ChatClientTests {
    func testAPIPrefixEncodesLiteralPathCharacters() throws {
        let endpoint = try ChatEndpoint(baseURL: URL(string: "http://localhost/base%20path")!, apiPrefix: "/custom prefix")
        XCTAssertEqual(endpoint.chatURL.path, "/base path/custom prefix/chat/completions")
    }
}

extension ChatClientTests {
    func testPreCancelledTaskDoesNotResolveOrSend() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient()
        let selected = profile(server.baseURL), messages = self.messages
        let task = Task {
            try? await Task.sleep(for: .seconds(1))
            return try await client.generate(task: .summary, route: TaskRoute(task: .summary), profiles: [selected], messages: messages)
        }
        task.cancel()
        await expectError(.cancelled) { _ = try await task.value }
        let records = try await server.records()
        XCTAssertTrue(records.isEmpty)
    }
    func testDiscoveryAlsoBlocksRedirects() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient()
        await expectError(.redirectRejected) {
            _ = try await client.discover(endpoint: ChatEndpoint(baseURL: server.url("redirect")), format: .openAI)
        }
        let records = try await server.records()
        XCTAssertEqual(records.count, 1)
    }
}

extension ChatClientTests {
    func testVerifiedNonChatRoutesAreRejectedBeforeHTTP() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient()
        for (task, kind) in [(TaskRole.fileASR, ModelKind.asr), (.embedding, .embedding), (.questionDetection, .detector)] {
            let selected = ProviderProfile(profileID: "selected", kind: kind, executionLocation: .onDevice,
                modelID: "explicit-model", locationVerified: true, verifiedCapabilities: [task], baseURL: server.baseURL)
            await expectError(.unsupportedChatRoute) {
                _ = try await client.generate(task: task, route: TaskRoute(task: task, profileID: "selected"),
                    profiles: [selected], messages: self.messages)
            }
        }
        let records = try await server.records()
        XCTAssertTrue(records.isEmpty)
    }
    func testOllamaDiscoveryRemovesOnlyTrailingV1FromNativePath() async throws {
        let server = try ChatServer(); defer { server.stop() }
        let client = try ChatClient()
        for (base, expected) in [("v1", "/api/tags"), ("proxy/v1", "/proxy/api/tags"), ("proxy", "/proxy/api/tags")] {
            let endpoint = try ChatEndpoint(baseURL: server.url(base))
            XCTAssertEqual(endpoint.ollamaTagsURL.path, expected)
            _ = try await client.discover(endpoint: endpoint, format: .ollama)
        }
        let records = try await server.records()
        XCTAssertEqual(records.compactMap { $0["path"] as? String }, ["/api/tags", "/proxy/api/tags", "/proxy/api/tags"])
    }
}

extension ChatClientTests {
    func testFixtureStartupTimeoutIsBoundedAndReapsChild() throws {
        let child = Process()
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let server = try ChatServer(process: child, startupTimeout: 0.1, startupDelay: 1.5)
            server.stop()
            XCTFail("Expected fixture startup timeout")
        } catch {
            guard case ChatServerError.startupTimedOut = error else {
                return XCTFail("Expected typed startup timeout")
            }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertFalse(child.isRunning)
        XCTAssertEqual(kill(child.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH, "Fixture child must be reaped")
    }
}
