import XCTest
@testable import MeetingCore

private actor JobGate {
    var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func hasEntered() -> Bool { entered }
}

final class TranscriptionJobTests: XCTestCase {
    @MainActor func testFailurePreservesPreviousResult() async {
        let job = TranscriptionJob()
        job.start(configuration: .init(), audioURL: URL(fileURLWithPath: "/first.wav")) { _, _ in .init(text: "真实结果", provenance: "test") }
        await job.waitUntilIdle()
        job.start(configuration: .init(), audioURL: URL(fileURLWithPath: "/bad.wav")) { _, _ in throw QwenASRError.invalidWAV }
        await job.waitUntilIdle()
        XCTAssertEqual(job.result?.text, "真实结果")
        XCTAssertEqual(job.resultAudioURL?.path, "/first.wav")
        XCTAssertNotNil(job.errorMessage)
    }
    @MainActor func testCancellationSuppressesLateOutputAndRemainsBusyUntilCleanup() async {
        let gate = JobGate(), job = TranscriptionJob()
        job.start(configuration: .init(), audioURL: URL(fileURLWithPath: "/original.wav")) { _, _ in .init(text: "先前结果", provenance: "test") }
        await job.waitUntilIdle()
        job.start(configuration: .init(), audioURL: URL(fileURLWithPath: "/a.wav")) { _, _ in
            await gate.wait() // Deliberately ignores cancellation, like an uninterruptible native call.
            return .init(text: "迟到结果", provenance: "test")
        }
        while !(await gate.hasEntered()) { await Task.yield() }
        job.cancel()
        XCTAssertTrue(job.isBusy)
        let admitted = job.start(configuration: .init(), audioURL: URL(fileURLWithPath: "/b.wav")) { _, _ in .init(text: "不应运行", provenance: "test") }
        XCTAssertFalse(admitted)
        await gate.release()
        await job.waitUntilIdle()
        XCTAssertEqual(job.result?.text, "先前结果")
        XCTAssertEqual(job.resultAudioURL?.path, "/original.wav")
        XCTAssertFalse(job.isBusy)
        XCTAssertEqual(job.status, "已取消")
    }
    @MainActor func testConfigurationIsSnapshot() async {
        let gate = JobGate(), job = TranscriptionJob()
        var configuration = TranscriptionConfiguration()
        configuration.qwenRevision = "original"
        job.start(configuration: configuration, audioURL: URL(fileURLWithPath: "/a.wav")) { snapshot, _ in
            await gate.wait()
            return .init(text: snapshot.qwenRevision, provenance: "test")
        }
        configuration.qwenRevision = "edited"
        while !(await gate.hasEntered()) { await Task.yield() }
        await gate.release()
        await job.waitUntilIdle()
        XCTAssertEqual(job.result?.text, "original")
        await job.shutdown()
        XCTAssertFalse(job.isBusy)
    }
    @MainActor func testShutdownWaitsForActiveCleanup() async {
        let gate = JobGate(), job = TranscriptionJob()
        job.start(configuration: .init(), audioURL: URL(fileURLWithPath: "/a.wav")) { _, _ in
            await gate.wait()
            return .init(text: "迟到结果", provenance: "test")
        }
        while !(await gate.hasEntered()) { await Task.yield() }
        var drained = false
        let shutdown = Task { await job.shutdown(); drained = true }
        while job.status != "正在取消并释放模型，请稍候…" { await Task.yield() }
        XCTAssertFalse(drained)
        XCTAssertTrue(job.isBusy)
        await gate.release()
        await shutdown.value
        XCTAssertTrue(drained)
        XCTAssertFalse(job.isBusy)
        XCTAssertNil(job.result)
    }
    func testProductionRejectsNonFileURLAndRelativeModelPath() async {
        var configuration = TranscriptionConfiguration()
        configuration.qwenModel = "relative-model"
        configuration.qwenRuntime = "/runtime.dylib"
        configuration.qwenRevision = "revision"
        do {
            _ = try await LocalTranscription.run(configuration, URL(string: "https://example.com/a.wav")!)
            XCTFail("Remote URL must be rejected before reading")
        } catch { XCTAssertTrue(LocalTranscription.message(for: error).contains("本地绝对路径")) }
        do {
            _ = try await LocalTranscription.run(configuration, URL(fileURLWithPath: "/missing.wav"))
            XCTFail("Relative model path must be rejected before reading")
        } catch { XCTAssertTrue(LocalTranscription.message(for: error).contains("本地绝对路径")) }
    }
    func testProductionRejectsOversizedLocalFileBeforeModelLoad() async throws {
        var configuration = TranscriptionConfiguration()
        configuration.qwenModel = "/model"
        configuration.qwenRuntime = "/runtime.dylib"
        configuration.qwenRevision = "revision"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0, count: 1_000_001).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do { _ = try await LocalTranscription.run(configuration, url); XCTFail() }
        catch { XCTAssertEqual(error as? QwenASRError, .audioTooLong) }
    }
    @MainActor func testEmptyActualTextHasExplicitStatus() async {
        let job = TranscriptionJob()
        job.start(configuration: .init(), audioURL: URL(fileURLWithPath: "/a.wav")) { _, _ in .init(text: "  \n", provenance: "test") }
        await job.waitUntilIdle()
        XCTAssertEqual(job.status, "未识别到语音")
        XCTAssertEqual(job.result?.text, "  \n")
    }
}
