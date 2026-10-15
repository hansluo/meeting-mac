import XCTest
import CryptoKit
@testable import MeetingCore

final class QwenASREngineTests: XCTestCase {
    func testMissingRuntimeProducesTypedFailure() {
        XCTAssertThrowsError(try QwenASREngine.probeRuntime(path: "/missing/sherpa.dylib")) {
            guard case QwenASRError.runtimeLoad = $0 else { return XCTFail("\($0)") }
        }
    }
    func testPCMContractRejectsEmptyNonFiniteClippedAndOversize() {
        for pcm: [Float] in [[], [.nan], [.infinity], [1.1], Array(repeating: 0, count: 16001)] {
            XCTAssertThrowsError(try QwenASREngine.validatePCM(pcm, sampleRate: 16000, maximumSeconds: 1))
        }
        XCTAssertNoThrow(try QwenASREngine.validatePCM([-1, 0, 1], sampleRate: 16000, maximumSeconds: 1))
    }
    func testOversizedPCMIsRejectedBeforeScanningSamples() {
        XCTAssertThrowsError(try QwenASREngine.validatePCM(Array(repeating: .nan, count: 16001), sampleRate: 16000, maximumSeconds: 1)) {
            XCTAssertEqual($0 as? QwenASRError, .audioTooLong)
        }
    }
    func testPCMContractRequiresExplicitNativeSampleRate() {
        for rate in [0, -1, 8000, 44100, 48000] {
            XCTAssertThrowsError(try QwenASREngine.validatePCM([0], sampleRate: rate, maximumSeconds: 1)) {
                XCTAssertEqual($0 as? QwenASRError, .unsupportedSampleRate(rate))
            }
        }
    }
    func testMissingModelIsRejectedBeforeNativeInitialization() throws {
        let configuration = QwenASRConfiguration(modelDirectory: URL(fileURLWithPath: "/missing/model"), runtimePath: "/missing/lib", revision: "qwen-test")
        XCTAssertThrowsError(try configuration.validateModel()) {
            guard case QwenASRError.modelFile = $0 else { return XCTFail("\($0)") }
        }
    }
    func testInvalidBoundsAndRevisionAreRejected() {
        for configuration in [QwenASRConfiguration(modelDirectory: URL(fileURLWithPath: "/missing"), runtimePath: "/missing", revision: ""), QwenASRConfiguration(modelDirectory: URL(fileURLWithPath: "/missing"), runtimePath: "/missing", revision: "r", threads: 0), QwenASRConfiguration(modelDirectory: URL(fileURLWithPath: "/missing"), runtimePath: "/missing", revision: "r", maximumSeconds: 0)] {
            XCTAssertThrowsError(try configuration.validateModel()) {
                XCTAssertEqual($0 as? QwenASRError, .invalidConfiguration)
            }
        }
    }
    func testWAVParsesPCM16AndRejectsUnsupportedAndTruncated() throws {
        let wav = makeWAV(rate: 16000, bits: 16, channels: 1)
        XCTAssertEqual(try QwenPCM16WAV.parse(wav), [0, -1, Float(32767) / 32768])
        for invalid in [Data(wav.dropLast()), makeWAV(rate: 48000, bits: 16, channels: 1), makeWAV(rate: 16000, bits: 32, channels: 1), makeWAV(rate: 16000, bits: 16, channels: 2)] {
            XCTAssertThrowsError(try QwenPCM16WAV.parse(invalid))
        }
    }
    func testAlreadyCancelledTaskDoesNotLoadNativeRuntime() async {
        let engine = QwenASREngine(configuration: QwenASRConfiguration(modelDirectory: URL(fileURLWithPath: "/missing"), runtimePath: "/missing", revision: "r"))
        let task = Task.detached { try? await Task.sleep(nanoseconds: 10_000_000); return try await engine.transcribe(samples: [0], sampleRate: 16000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testMalformedModelsAndChangedManifestAreRejected() throws {
        let fixture = try fixture(mode: "success")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let config = fixture.configuration
        try config.validateModel()
        var hashes: [String: String] = [:]
        for file in QwenASRConfiguration.requiredFiles {
            let data = try Data(contentsOf: config.modelDirectory.appendingPathComponent(file))
            hashes[file] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let verified = QwenASRConfiguration(modelDirectory: config.modelDirectory, runtimePath: config.runtimePath, revision: "test", expectedSHA256: hashes)
        try verified.validateModel()
        try Data("changed".utf8).write(to: config.modelDirectory.appendingPathComponent("encoder.int8.onnx"))
        XCTAssertThrowsError(try verified.validateModel()) { XCTAssertEqual($0 as? QwenASRError, .modelHash("encoder.int8.onnx")) }
        try Data().write(to: config.modelDirectory.appendingPathComponent("decoder.int8.onnx"))
        XCTAssertThrowsError(try config.validateModel()) { XCTAssertEqual($0 as? QwenASRError, .modelFile("decoder.int8.onnx")) }
    }
    func testSymbolsAndVersionAreVerifiedAndLibraryUnloaded() throws {
        for mode in ["missing", "version"] {
            let f = try fixture(mode: mode)
            defer { try? FileManager.default.removeItem(at: f.directory) }
            XCTAssertThrowsError(try QwenASREngine.probeRuntime(path: f.configuration.runtimePath)) {
                switch ($0, mode) {
                case (QwenASRError.missingSymbol, "missing"), (QwenASRError.runtimeVersion, "version"): break
                default: XCTFail("Unexpected \($0)")
                }
            }
            XCTAssertEqual(try String(contentsOf: f.trace, encoding: .utf8), "load\nunload\n")
        }
    }
    func testFailedInitializationUnloadsLibrary() async throws {
        let f = try fixture(mode: "create-fail")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        do { _ = try await QwenASREngine(configuration: f.configuration).transcribe(samples: [0], sampleRate: 16000); XCTFail("Expected failure") }
        catch { guard case QwenASRError.nativeFailure = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(try String(contentsOf: f.trace, encoding: .utf8), "load\ncreate\nunload\n")
    }
    func testCancellationAfterFailedNativeLoadReturnsCancellationAndUnloads() async throws {
        let f = try fixture(mode: "slow-create-fail")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let engine = QwenASREngine(configuration: f.configuration)
        let task = Task.detached { try await engine.transcribe(samples: [0], sampleRate: 16000) }
        for _ in 0..<600 {
            if (try? String(contentsOf: f.trace, encoding: .utf8))?.contains("create") == true { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(try String(contentsOf: f.trace, encoding: .utf8).hasSuffix("unload\n"))
    }
    func testCancellationDuringAcceptSkipsDecodeAndFreesStream() async throws {
        let f = try fixture(mode: "slow-accept")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let engine = QwenASREngine(configuration: f.configuration)
        let task = Task.detached { try await engine.transcribe(samples: [0], sampleRate: 16000) }
        for _ in 0..<600 {
            if (try? String(contentsOf: f.trace, encoding: .utf8))?.contains("accept") == true { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let trace = try String(contentsOf: f.trace, encoding: .utf8)
        XCTAssertFalse(trace.contains("decode"))
        XCTAssertTrue(trace.hasSuffix("destroy-stream\ndestroy-recognizer\nunload\n"))
    }
    func testNativeDecodeFailuresFreeOwnedObjects() async throws {
        for mode in ["stream-fail", "result-fail", "decode-throw"] {
            let f = try fixture(mode: mode)
            defer { try? FileManager.default.removeItem(at: f.directory) }
            do { _ = try await QwenASREngine(configuration: f.configuration).transcribe(samples: [0], sampleRate: 16000); XCTFail("Expected failure") }
            catch { guard case QwenASRError.nativeFailure = error else { return XCTFail("\(error)") } }
            let trace = try String(contentsOf: f.trace, encoding: .utf8)
            XCTAssertTrue(trace.hasSuffix("destroy-recognizer\nunload\n"))
            XCTAssertEqual(trace.contains("destroy-stream"), mode != "stream-fail")
            XCTAssertFalse(trace.contains("destroy-result"))
        }
    }
    func testShimUsesOnlyQwenCPUConfigAndCopiesRawTextBeforeFree() async throws {
        let f = try fixture(mode: "success")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let engine = QwenASREngine(configuration: f.configuration)
        let result = try await engine.transcribe(samples: [0], sampleRate: 16000)
        XCTAssertEqual(result.text, " raw ASR ")
        XCTAssertEqual(result.runtimeVersion, "1.13.7")
        XCTAssertFalse(result.integrityManifestVerified)
        let trace = try String(contentsOf: f.trace, encoding: .utf8)
        XCTAssertEqual(trace, "load\ncreate\nstream\naccept\ndecode\nresult\ndestroy-result\ndestroy-stream\n")
        _ = try await engine.transcribe(samples: [0], sampleRate: 16000)
        try await engine.shutdown()
    }
    func testBusyAndCancellationWaitForNativeCleanup() async throws {
        let f = try fixture(mode: "slow")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let engine = QwenASREngine(configuration: f.configuration)
        let task = Task.detached { try await engine.transcribe(samples: [0], sampleRate: 16000) }
        for _ in 0..<600 {
            if (try? String(contentsOf: f.trace, encoding: .utf8))?.contains("decode") == true { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue((try String(contentsOf: f.trace, encoding: .utf8)).contains("decode"))
        do { _ = try await engine.transcribe(samples: [0], sampleRate: 16000); XCTFail("Expected busy") }
        catch { XCTAssertEqual(error as? QwenASRError, .busy) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try String(contentsOf: f.trace, encoding: .utf8).hasSuffix("destroy-recognizer\nunload\n"))
        let completed = try await engine.transcribe(samples: [0], sampleRate: 16000)
        XCTAssertGreaterThanOrEqual(completed.elapsedSeconds, 0.45)
        XCTAssertLessThan(completed.elapsedSeconds, 30)
        try await engine.shutdown()
    }
    func testResidentRecognizerReusesTwoDifferentJobs() async throws {
        let f = try fixture(mode: "success")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        var engine: QwenASREngine? = QwenASREngine(configuration: f.configuration)
        let first = try await engine!.transcribe(samples: [0], sampleRate: 16000)
        let second = try await engine!.transcribe(samples: [0.25, -0.5], sampleRate: 16000)
        XCTAssertEqual(first.revision, second.revision)
        XCTAssertEqual(second.sampleCount, 2)
        XCTAssertEqual(first.reusedRecognizer, false)
        XCTAssertEqual(second.reusedRecognizer, true)
        XCTAssertGreaterThanOrEqual(first.loadSeconds ?? -1, 0)
        XCTAssertEqual(second.loadSeconds, 0)
        XCTAssertGreaterThanOrEqual(second.decodeSeconds ?? -1, 0)
        XCTAssertGreaterThanOrEqual(second.elapsedSeconds, second.decodeSeconds ?? .infinity)
        let trace = try String(contentsOf: f.trace, encoding: .utf8)
        XCTAssertEqual(trace.components(separatedBy: "create\n").count - 1, 1)
        XCTAssertEqual(trace.components(separatedBy: "destroy-stream\n").count - 1, 2)
        XCTAssertEqual(trace.components(separatedBy: "destroy-result\n").count - 1, 2)
        XCTAssertFalse(trace.contains("destroy-recognizer"))
        weak let weakEngine = engine
        engine = nil
        for _ in 0..<100 where weakEngine != nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(weakEngine)
        XCTAssertTrue(try String(contentsOf: f.trace, encoding: .utf8).hasSuffix("destroy-recognizer\nunload\n"))
    }
    func testShutdownReleasesOnceAndLaterJobReloadsSameConfiguration() async throws {
        let f = try fixture(mode: "success")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let engine = QwenASREngine(configuration: f.configuration)
        _ = try await engine.transcribe(samples: [0], sampleRate: 16000)
        try await engine.shutdown()
        try await engine.shutdown()
        var trace = try String(contentsOf: f.trace, encoding: .utf8)
        XCTAssertEqual(trace.components(separatedBy: "destroy-recognizer\n").count - 1, 1)
        let result = try await engine.transcribe(samples: [0.5], sampleRate: 16000)
        XCTAssertEqual(result.revision, f.configuration.revision)
        try await engine.shutdown()
        trace = try String(contentsOf: f.trace, encoding: .utf8)
        XCTAssertEqual(trace.components(separatedBy: "create\n").count - 1, 2)
        XCTAssertEqual(trace.components(separatedBy: "destroy-recognizer\n").count - 1, 2)
    }
    func testShutdownDuringDecodeCancelsAndWaitsForNativeReturn() async throws {
        let f = try fixture(mode: "slow")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let engine = QwenASREngine(configuration: f.configuration)
        let job = Task.detached { try await engine.transcribe(samples: [0], sampleRate: 16000) }
        try await waitFor("decode", in: f)
        try await engine.shutdown()
        do { _ = try await job.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try String(contentsOf: f.trace, encoding: .utf8).hasSuffix("destroy-stream\ndestroy-recognizer\nunload\n"))
        _ = try await engine.transcribe(samples: [0.5], sampleRate: 16000)
        try await engine.shutdown()
    }
    func testChangedResidentModelAndTokenizerRejectBeforeDecodeAndInvalidate() async throws {
        for file in ["encoder.int8.onnx", "tokenizer/vocab.json"] {
            let f = try fixture(mode: "success")
            defer { try? FileManager.default.removeItem(at: f.directory) }
            let engine = QwenASREngine(configuration: f.configuration)
            _ = try await engine.transcribe(samples: [0], sampleRate: 16000)
            try Data("changed-checkpoint".utf8).write(to: f.configuration.modelDirectory.appendingPathComponent(file))
            do { _ = try await engine.transcribe(samples: [0.5], sampleRate: 16000); XCTFail("Expected changed file rejection") }
            catch { XCTAssertEqual(error as? QwenASRError, .modelFile(file)) }
            let trace = try String(contentsOf: f.trace, encoding: .utf8)
            XCTAssertEqual(trace.components(separatedBy: "decode\n").count - 1, 1)
            XCTAssertTrue(trace.hasSuffix("destroy-recognizer\nunload\n"))
        }
    }
    func testNativeFailureInvalidatesBeforeNextJob() async throws {
        let f = try fixture(mode: "result-fail")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let engine = QwenASREngine(configuration: f.configuration)
        for _ in 0..<2 {
            do { _ = try await engine.transcribe(samples: [0], sampleRate: 16000); XCTFail("Expected failure") }
            catch { guard case QwenASRError.nativeFailure = error else { return XCTFail("\(error)") } }
        }
        let trace = try String(contentsOf: f.trace, encoding: .utf8)
        XCTAssertEqual(trace.components(separatedBy: "create\n").count - 1, 2)
        XCTAssertEqual(trace.components(separatedBy: "destroy-recognizer\n").count - 1, 2)
    }
    func testBusyJobRetainsEngineUntilNativeCleanup() async throws {
        let f = try fixture(mode: "slow")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        var engine: QwenASREngine? = QwenASREngine(configuration: f.configuration)
        weak let weakEngine = engine
        let job = Task.detached { [owned = engine!] in try await owned.transcribe(samples: [0], sampleRate: 16000) }
        try await waitFor("decode", in: f)
        engine = nil
        XCTAssertNotNil(weakEngine)
        _ = try await job.value
        for _ in 0..<100 where weakEngine != nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(weakEngine)
        XCTAssertTrue(try String(contentsOf: f.trace, encoding: .utf8).hasSuffix("destroy-recognizer\nunload\n"))
    }
    func testTrustedManifestRevalidatedAfterChangedResidentFile() async throws {
        let f = try fixture(mode: "success")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        var hashes: [String: String] = [:]
        for file in QwenASRConfiguration.requiredFiles {
            hashes[file] = SHA256.hash(data: try Data(contentsOf: f.configuration.modelDirectory.appendingPathComponent(file))).map { String(format: "%02x", $0) }.joined()
        }
        let config = QwenASRConfiguration(modelDirectory: f.configuration.modelDirectory, runtimePath: f.configuration.runtimePath, revision: "trusted-revision", expectedSHA256: hashes)
        let engine = QwenASREngine(configuration: config)
        let result = try await engine.transcribe(samples: [0], sampleRate: 16000)
        XCTAssertTrue(result.integrityManifestVerified)
        let file = "tokenizer/merges.txt", url = config.modelDirectory.appendingPathComponent(file)
        // Same-size mutation also changes mtime: size alone is insufficient.
        try Data("changed".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: url.path)
        do { _ = try await engine.transcribe(samples: [0], sampleRate: 16000); XCTFail("Expected signature failure") }
        catch { XCTAssertEqual(error as? QwenASRError, .modelFile(file)) }
        do { _ = try await engine.transcribe(samples: [0], sampleRate: 16000); XCTFail("Expected manifest failure on reload") }
        catch { XCTAssertEqual(error as? QwenASRError, .modelHash(file)) }
        let trace = try String(contentsOf: f.trace, encoding: .utf8)
        XCTAssertEqual(trace.components(separatedBy: "create\n").count - 1, 1)
        XCTAssertEqual(trace.components(separatedBy: "decode\n").count - 1, 1)
    }
    func testConcurrentShutdownDrainsOnlyOnceAndRejectsQueuedJobs() async throws {
        let f = try fixture(mode: "slow")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let engine = QwenASREngine(configuration: f.configuration)
        let job = Task.detached { try await engine.transcribe(samples: [0], sampleRate: 16000) }
        try await waitFor("decode", in: f)
        async let first: Void = engine.shutdown()
        async let second: Void = engine.shutdown()
        for _ in 0..<8 {
            do { _ = try await engine.transcribe(samples: [0.5], sampleRate: 16000); XCTFail("Expected bounded admission") }
            catch { XCTAssertEqual(error as? QwenASRError, .busy) }
        }
        try await first; try await second
        do { _ = try await job.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let trace = try String(contentsOf: f.trace, encoding: .utf8)
        XCTAssertEqual(trace.components(separatedBy: "decode\n").count - 1, 1)
        XCTAssertEqual(trace.components(separatedBy: "destroy-recognizer\n").count - 1, 1)
    }
    func testResultDecodesOlderMetadataWithoutResidentTimingFields() throws {
        let data = Data(#"{"text":"old","modelDirectory":"/model","revision":"r","runtimePath":"/lib","runtimeVersion":"1.13.7","elapsedSeconds":1,"sampleCount":1,"sampleRate":16000,"integrityManifestVerified":false}"#.utf8)
        let result = try JSONDecoder().decode(QwenASRResult.self, from: data)
        XCTAssertNil(result.reusedRecognizer)
        XCTAssertNil(result.loadSeconds)
        XCTAssertNil(result.decodeSeconds)
    }
    func testCancellationDuringSuccessfulInitializationOwnsAndReleasesHandle() async throws {
        let f = try fixture(mode: "slow-create-success")
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let engine = QwenASREngine(configuration: f.configuration)
        let job = Task.detached { try await engine.transcribe(samples: [0], sampleRate: 16000) }
        try await waitFor("create", in: f)
        job.cancel()
        do { _ = try await job.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try String(contentsOf: f.trace, encoding: .utf8), "load\ncreate\ndestroy-recognizer\nunload\n")
    }
    func testInvalidEngineConfigurationRejectedBeforeMissingFiles() async {
        let engine = QwenASREngine(configuration: QwenASRConfiguration(modelDirectory: URL(fileURLWithPath: "/missing/model"), runtimePath: "/missing/lib", revision: "", threads: 0))
        do { _ = try await engine.transcribe(samples: [0], sampleRate: 16000); XCTFail("Expected invalid configuration") }
        catch { XCTAssertEqual(error as? QwenASRError, .invalidConfiguration) }
    }
    private func waitFor(_ marker: String, in f: Fixture) async throws {
        for _ in 0..<600 {
            if (try? String(contentsOf: f.trace, encoding: .utf8))?.contains(marker) == true { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Native fixture did not reach \(marker)")
    }
    // Controlled native ABI fixture tests failures and ownership; never real ASR evidence.
    private struct Fixture {
        let directory: URL
        let trace: URL
        let configuration: QwenASRConfiguration
    }
    private func fixture(mode: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let trace = directory.appendingPathComponent("trace")
        let model = directory.appendingPathComponent("model")
        for file in QwenASRConfiguration.requiredFiles {
            let url = model.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        let library = directory.appendingPathComponent("fixture.dylib")
        let source = directory.appendingPathComponent("fixture.cpp")
        let code = """
        #include "c-api.h"
        #include <cstdio>
        #include <cstring>
        #include <stdexcept>
        #include <unistd.h>
        static void mark(const char *s) { FILE *f = fopen("\(trace.path)", "a"); fprintf(f, "%s\\n", s); fclose(f); }
        __attribute__((constructor)) static void loaded() { mark("load"); }
        __attribute__((destructor)) static void unloaded() { mark("unload"); }
        extern "C" {
        const char *SherpaOnnxGetVersionStr() { return "\(mode == "version" ? "0.0.0" : "1.13.7")"; }
        const SherpaOnnxOfflineRecognizer *SherpaOnnxCreateOfflineRecognizer(const SherpaOnnxOfflineRecognizerConfig *c) {
          mark("create");
          \(mode == "slow-create-success" ? "usleep(200000);" : "")
          \(mode == "slow-create-fail" ? "usleep(200000); return nullptr;" : "")
          if (\(mode == "create-fail" ? "true" : "false")) return nullptr;
          SherpaOnnxOfflineRecognizerConfig expected{};
          expected.feat_config.sample_rate=16000; expected.feat_config.feature_dim=80;
          expected.model_config.num_threads=4; expected.model_config.provider=c->model_config.provider;
          expected.decoding_method=c->decoding_method; expected.model_config.qwen3_asr=c->model_config.qwen3_asr;
          if (memcmp(c,&expected,sizeof(expected)) || strcmp(c->model_config.provider,"cpu") || strcmp(c->decoding_method,"greedy_search") || c->model_config.qwen3_asr.max_total_len!=4096 || c->model_config.qwen3_asr.max_new_tokens!=1024 || !c->model_config.qwen3_asr.conv_frontend || !c->model_config.qwen3_asr.encoder || !c->model_config.qwen3_asr.decoder || !c->model_config.qwen3_asr.tokenizer) return nullptr;
          return reinterpret_cast<const SherpaOnnxOfflineRecognizer *>(1);
        }
        void SherpaOnnxDestroyOfflineRecognizer(const SherpaOnnxOfflineRecognizer *) { mark("destroy-recognizer"); }
        const SherpaOnnxOfflineStream *SherpaOnnxCreateOfflineStream(const SherpaOnnxOfflineRecognizer *) { mark("stream"); return \(mode == "stream-fail" ? "nullptr" : "reinterpret_cast<const SherpaOnnxOfflineStream *>(2)"); }
        void SherpaOnnxDestroyOfflineStream(const SherpaOnnxOfflineStream *) { mark("destroy-stream"); }
        void SherpaOnnxAcceptWaveformOffline(const SherpaOnnxOfflineStream *, int32_t rate, const float *, int32_t n) { if(rate!=16000 || n<=0) throw std::runtime_error("PCM"); mark("accept"); \(mode == "slow-accept" ? "usleep(500000);" : "") }
        void SherpaOnnxDecodeOfflineStream(const SherpaOnnxOfflineRecognizer *, const SherpaOnnxOfflineStream *) { mark("decode"); \(mode == "decode-throw" ? "throw std::runtime_error(\"decode failure\");" : "") \(mode == "slow" ? "usleep(500000);" : "") }
        const SherpaOnnxOfflineRecognizerResult *SherpaOnnxGetOfflineStreamResult(const SherpaOnnxOfflineStream *) { mark("result"); if(\(mode == "result-fail" ? "true" : "false")) return nullptr; static SherpaOnnxOfflineRecognizerResult r{}; r.text=" raw ASR "; return &r; }
        \(mode == "missing" ? "" : "void SherpaOnnxDestroyOfflineRecognizerResult(const SherpaOnnxOfflineRecognizerResult *) { mark(\"destroy-result\"); }")
        }
        """
        try code.write(to: source, atomically: true, encoding: .utf8)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["clang++", "-std=c++17", "-dynamiclib", "-I", root.appendingPathComponent("ThirdParty/sherpa-onnx").path, source.path, "-o", library.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw QwenASRError.nativeFailure("Fixture compilation") }
        return Fixture(directory: directory, trace: trace, configuration: QwenASRConfiguration(modelDirectory: model, runtimePath: library.path, revision: "fixture-not-real-ASR"))
    }
    private func makeWAV(rate: UInt32, bits: UInt16, channels: UInt16) -> Data {
        var data = Data("RIFF".utf8)
        func u16(_ n: UInt16) { data.append(contentsOf: [UInt8(n & 255), UInt8(n >> 8)]) }
        func u32(_ n: UInt32) { data.append(contentsOf: (0..<4).map { UInt8((n >> ($0 * 8)) & 255) }) }
        u32(42); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(channels); u32(rate); u32(rate * UInt32(channels) * UInt32(bits / 8)); u16(channels * (bits / 8)); u16(bits)
        data.append(Data("data".utf8)); u32(6); u16(0); u16(32768); u16(32767)
        return data
    }
}
