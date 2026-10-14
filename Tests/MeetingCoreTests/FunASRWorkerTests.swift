import XCTest
import Darwin
@testable import MeetingCore

final class FunASRWorkerTests: XCTestCase {
    private var fixture: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/funasr_test_worker.py") }
    private func client(_ mode: String = "normal", timeout: Double = 1, directory: URL? = nil) -> FunASRWorker {
        FunASRWorker(configuration: .init(pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"), workerScript: fixture, modelDirectory: directory ?? URL(fileURLWithPath: "/tmp/\(mode)"), checkpoint: "model.pt", revision: "fixture", startupTimeout: timeout, requestTimeout: timeout))
    }
    private func audio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        var d = Data("RIFF".utf8)
        func u16(_ n: UInt16) { d.append(contentsOf: [UInt8(n & 255), UInt8(n >> 8)]) }
        func u32(_ n: UInt32) { u16(UInt16(n & 65535)); u16(UInt16(n >> 16)) }
        u32(68); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16); d.append(Data("data".utf8)); u32(32); d.append(Data(repeating:0,count:32))
        try d.write(to:url); return url
    }
    func testRealPipeRoundTripAndImportProbeIsNotASRVerification() async throws {
        let worker = client(); let probe = try await worker.probeRuntime()
        XCTAssertFalse(probe.asrVerified); XCTAssertFalse(probe.modelLoaded)
        let url = try audio(); defer { try? FileManager.default.removeItem(at:url) }
        let residentPID = worker.processIdentifier
        for _ in 0..<3 {
            let result = try await worker.transcribe(wavURL:url)
            XCTAssertEqual(worker.processIdentifier, residentPID)
            XCTAssertEqual(result.rawText, "<|zh|>你好"); XCTAssertEqual(result.text,"你好")
        }
        try await worker.shutdown(); XCTAssertFalse(worker.hasRunningProcess)
    }
    func testRejectsInvalidProbeBooleanAndConfiguration() async throws {
        do { _ = try await client("bad_probe").probeRuntime(); XCTFail() } catch { XCTAssertEqual(error as? FunASRWorkerError,.protocolViolation) }
        let invalid = FunASRWorker(configuration:.init(pythonExecutable:URL(fileURLWithPath:"/usr/bin/python3"),workerScript:fixture,modelDirectory:URL(fileURLWithPath:"/tmp/normal"),checkpoint:"model.pt",revision:""))
        do { _ = try await invalid.probeRuntime(); XCTFail() } catch { XCTAssertEqual(error as? FunASRWorkerError,.invalidConfiguration) }
        XCTAssertFalse(invalid.hasRunningProcess)
    }
    func testRejectsMissingRuntimeAndInvalidAudio() async throws {
        let missing = FunASRWorker(configuration:.init(pythonExecutable:URL(fileURLWithPath:"/missing"), workerScript:fixture, modelDirectory:URL(fileURLWithPath:"/tmp/normal"),checkpoint:"model.pt",revision:"r"))
        do { _ = try await missing.probeRuntime(); XCTFail() } catch { XCTAssertEqual(error as? FunASRWorkerError,.runtimeUnavailable) }
        do { _ = try await client().transcribe(wavURL:URL(fileURLWithPath:"/missing")); XCTFail() } catch { XCTAssertEqual(error as? FunASRWorkerError,.invalidAudio) }
    }
    func testRejectsMalformedNoiseOversizedUnknownJobAndCrash() async throws {
        let url = try audio(); defer { try? FileManager.default.removeItem(at:url) }
        for mode in ["noise","oversized","malformed","unknown_job","crash","wrong_version","version_true"] {
            do { _ = try await client(mode).transcribe(wavURL:url); XCTFail(mode) } catch { XCTAssertEqual(error as? FunASRWorkerError, mode == "crash" ? .workerExited : .protocolViolation, mode) }
        }
    }
    func testTimeoutsAndCancellationReapAndAllowRestart() async throws {
        let url = try audio(); defer { try? FileManager.default.removeItem(at:url) }
        for mode in ["startup_timeout", "request_timeout"] {
            do { _ = try await client(mode,timeout:0.1).transcribe(wavURL:url); XCTFail() } catch { XCTAssertEqual(error as? FunASRWorkerError,.timedOut) }
        }
        let worker = client("request_timeout",timeout:5)
        let task = Task { try await worker.transcribe(wavURL:url) }
        try await Task.sleep(for:.milliseconds(100)); let oldPID = worker.processIdentifier; task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual(error as? FunASRWorkerError,.cancelled) }
        XCTAssertFalse(worker.hasRunningProcess)
        if let oldPID { XCTAssertEqual(kill(oldPID,0), -1); XCTAssertEqual(errno, ESRCH) }
        let probe = try await worker.probeRuntime(); XCTAssertFalse(probe.asrVerified)
        XCTAssertNotEqual(worker.processIdentifier, oldPID)
        XCTAssertTrue(worker.hasRunningProcess)
        try await worker.shutdown(); XCTAssertFalse(worker.hasRunningProcess)
    }
    func testCrashAndBothTimeoutsReapThenRestartSameClient() async throws {
        let audioURL = try audio(); defer { try? FileManager.default.removeItem(at:audioURL) }
        for mode in ["crash", "startup_timeout", "request_timeout"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let directory = root.appendingPathComponent(mode + "_once")
            defer { try? FileManager.default.removeItem(at:root) }
            let worker = client(mode,timeout:0.3,directory:directory)
            do { _ = try await worker.transcribe(wavURL:audioURL); XCTFail(mode) }
            catch { XCTAssertEqual(error as? FunASRWorkerError,mode == "crash" ? .workerExited : .timedOut) }
            let firstJournal = try String(contentsOf:directory.appendingPathComponent("pids"),encoding:.utf8)
            let firstPID = try XCTUnwrap(Int32(firstJournal.trimmingCharacters(in:.whitespacesAndNewlines)))
            XCTAssertFalse(worker.hasRunningProcess)
            XCTAssertEqual(kill(firstPID,0),-1); XCTAssertEqual(errno,ESRCH)
            let result = try await worker.transcribe(wavURL:audioURL)
            XCTAssertEqual(result.text,"你好")
            let nextPID = try XCTUnwrap(worker.processIdentifier)
            XCTAssertNotEqual(firstPID,nextPID)
            let journal = try String(contentsOf:directory.appendingPathComponent("pids"),encoding:.utf8).split(separator:"\n")
            XCTAssertEqual(journal.count,2)
            XCTAssertEqual(Int32(journal[1]),nextPID)
            try await worker.shutdown()
            XCTAssertEqual(kill(nextPID,0),-1); XCTAssertEqual(errno,ESRCH)
        }
    }
    func testBrokenStdinDoesNotSignalHost() async throws {
        if ProcessInfo.processInfo.environment["FUNASR_PIPE_HOST"] == "1" {
            signal(SIGPIPE, SIG_DFL)
            let worker = client("broken_stdin")
            do { _ = try await worker.probeRuntime(); XCTFail() } catch { XCTAssertEqual(error as? FunASRWorkerError,.workerExited) }
            XCTAssertFalse(worker.hasRunningProcess)
            return
        }
        let host = Process()
        host.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
        host.arguments = ["-XCTest", "MeetingCoreTests.FunASRWorkerTests/testBrokenStdinDoesNotSignalHost", Bundle(for:Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment; environment["FUNASR_PIPE_HOST"] = "1"; host.environment = environment
        host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
        try host.run(); host.waitUntilExit()
        XCTAssertEqual(host.terminationReason,.exit)
        XCTAssertEqual(host.terminationStatus,0)
    }
    func testBusyDoesNotStartSecondProcess() async throws {
        let url = try audio(); defer { try? FileManager.default.removeItem(at:url) }
        let worker = client("request_timeout",timeout:5)
        let first = Task { try await worker.transcribe(wavURL:url) }
        try await Task.sleep(for:.milliseconds(100))
        do { _ = try await worker.probeRuntime(); XCTFail() } catch { XCTAssertEqual(error as? FunASRWorkerError,.busy) }
        first.cancel(); _ = try? await first.value
    }
}
