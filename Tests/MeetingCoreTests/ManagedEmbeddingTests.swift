import XCTest
import CryptoKit
import Darwin
@testable import MeetingCore

final class ManagedEmbeddingTests: XCTestCase, @unchecked Sendable {
    private func fixture(timeout: Double = 5) async throws -> (URL, URL, ManagedEmbeddingService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/embedding_server.py")
        let bytes = try Data(contentsOf: fixture)
        var assets: [ManagedAsset] = []
        for (id, name, data) in [("embeddinggemma300m", "model.gguf", Data("model".utf8)), ("llama-server-ollama0.40.4", "llama-server", bytes)] {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let directory = root.appendingPathComponent(id).appendingPathComponent(hash)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appendingPathComponent(name).path)
            assets.append(ManagedAsset(id: id, name: id, url: URL(string: "http://127.0.0.1:1")!, size: Int64(data.count), sha256: hash, archiveRoot: nil, files: [.init(path: name, size: Int64(data.count), sha256: hash)]))
        }
        let model = root.appendingPathComponent(assets[0].id).appendingPathComponent(assets[0].version)
        return (root, model, ManagedEmbeddingService(store: ManagedAssetStore(root: root, assets: assets), timeout: timeout))
    }
    private func waitFor(_ file: URL) async throws {
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: file.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Fixture did not start")
    }
    func testOwnedHelperPrefixesNormalizationProvenanceReuseAndShutdownRestart() async throws {
        let (root, model, service) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let inputs: [EmbeddingInput] = [.query("会议结论"), .document(title: "预算", text: "团队增加预算")]
        let first = try await service.embed(inputs)
        XCTAssertEqual(first.map(\.input), inputs)
        XCTAssertEqual(first[0].vector.count, 768)
        XCTAssertEqual(first[0].vector[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(first[0].vector[1], 0.8, accuracy: 0.0001)
        XCTAssertEqual(first[0].executionLocation, .onDevice)
        XCTAssertEqual(first[0].model, ManagedEmbeddingService.model)
        XCTAssertTrue(first[0].runtimeRevision.hasPrefix("llama-server-ollama0.40.4:"))
        XCTAssertEqual(first[0].checkpointSHA256, SHA256.hash(data: Data("model".utf8)).map { String(format: "%02x", $0) }.joined())
        let pid = try String(contentsOf: model.appendingPathComponent("pid"), encoding: .utf8)
        _ = try await service.embed([.query("复用")])
        XCTAssertEqual(try String(contentsOf: model.appendingPathComponent("pid"), encoding: .utf8), pid)
        let records = try String(contentsOf: model.appendingPathComponent("records"), encoding: .utf8)
        XCTAssertTrue(records.contains("task: search result | query: "))
        XCTAssertTrue(records.contains("title: "))
        let env = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: model.appendingPathComponent("environment")))
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        for secret in ["OPENAI_API_KEY", "DEEPSEEK_API_KEY", "HF_TOKEN", "HTTP_PROXY", "HTTPS_PROXY", "HOME"] { XCTAssertNil(env[secret]) }
        await service.shutdown()
        XCTAssertEqual(kill(Int32(pid)!, 0), -1)
        _ = try await service.embed([.query("重启")])
        XCTAssertNotEqual(try String(contentsOf: model.appendingPathComponent("pid"), encoding: .utf8), pid)
        await service.shutdown()
    }
    func testMalformedResponseFailuresInvalidateAndRestart() async throws {
        let (root, model, service) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for mode in ["zero", "dimension", "nan", "index", "missing", "duplicate", "model", "oversize", "context", "status", "redirect", "crash", "badready", "startupcrash", "unauthenticated"] {
            await service.shutdown()
            try Data(mode.utf8).write(to: model.appendingPathComponent("mode"))
            do { _ = try await service.embed([.query("PRIVATE")]); XCTFail(mode) }
            catch {
                XCTAssertFalse(String(describing: error).contains("PRIVATE"))
                let expected: ManagedEmbeddingError
                switch mode {
                case "oversize": expected = .responseTooLarge
                case "context": expected = .contextExceeded
                case "status": expected = .httpStatus(500)
                case "redirect": expected = .httpStatus(302)
                case "crash": expected = .transport
                case "startupcrash": expected = .helperExited
                case "unauthenticated": expected = .httpStatus(200)
                default: expected = .invalidResponse
                }
                XCTAssertEqual(error as? ManagedEmbeddingError, expected, mode)
            }
            let pid = try String(contentsOf: model.appendingPathComponent("pid"), encoding: .utf8)
            XCTAssertEqual(kill(Int32(pid)!, 0), -1, mode)
            try Data().write(to: model.appendingPathComponent("mode"))
            _ = try await service.embed([.query("恢复")])
        }
        await service.shutdown()
    }
    func testStartupAndRequestDeadlinesCancelBusyDrainAndRecovery() async throws {
        for mode in ["startup", "slow", "trickle"] {
            let (root, model, service) = try await fixture(timeout: 1.2); defer { try? FileManager.default.removeItem(at: root) }
            try Data(mode.utf8).write(to: model.appendingPathComponent("mode"))
            let start = Date()
            do { _ = try await service.embed([.query("deadline")]); XCTFail() } catch { }
            XCTAssertLessThan(Date().timeIntervalSince(start), 3.2)
            let pid = try String(contentsOf: model.appendingPathComponent("pid"), encoding: .utf8)
            XCTAssertEqual(kill(Int32(pid)!, 0), -1)
            await service.shutdown()
        }
        let (root, model, service) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("slow".utf8).write(to: model.appendingPathComponent("mode"))
        let job = Task { try await service.embed([.query("取消")]) }
        try await waitFor(model.appendingPathComponent("records"))
        do { _ = try await service.embed([.query("busy")]); XCTFail() } catch { XCTAssertEqual(error as? ManagedEmbeddingError, .busy) }
        job.cancel()
        do { _ = try await job.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let pid = try String(contentsOf: model.appendingPathComponent("pid"), encoding: .utf8)
        XCTAssertEqual(kill(Int32(pid)!, 0), -1)
        try Data().write(to: model.appendingPathComponent("mode"))
        _ = try await service.embed([.query("恢复")])
        try Data("slow".utf8).write(to: model.appendingPathComponent("mode"))
        let active = Task { try await service.embed([.query("关闭")]) }
        try await Task.sleep(for: .milliseconds(100))
        let firstShutdown = Task { await service.shutdown() }
        try await Task.sleep(for: .milliseconds(20))
        let secondShutdown = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await service.shutdown()
        }
        await secondShutdown.value
        try Data().write(to: model.appendingPathComponent("mode"))
        // The cancelled second shutdown must fully drain and release admission even
        // when the original embed wrapper has not yet resumed its actor defer.
        _ = try await service.embed([.query("双重关闭后恢复")])
        await firstShutdown.value
        do { _ = try await active.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await service.shutdown()
    }
    func testMissingManagedAssetsNeverContactsDaemon() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = ManagedEmbeddingService(store: ManagedAssetStore(root: root))
        do { _ = try await service.embed([.query("会议")]); XCTFail() }
        catch { XCTAssertEqual(error as? ManagedEmbeddingError, .assetsUnavailable) }
        await service.shutdown()
    }
    func testEmptyAndOversizedInputsRejectedBeforeLaunch() async throws {
        let service = ManagedEmbeddingService()
        let cases: [[EmbeddingInput]] = [[], [.query(" ")], [.query(String(repeating: "a", count: 16001))], Array(repeating: .query("a"), count: 17)]
        for inputs in cases {
            do { _ = try await service.embed(inputs); XCTFail() }
            catch { XCTAssertEqual(error as? ManagedEmbeddingError, .invalidInput) }
        }
        await service.shutdown()
    }
}
