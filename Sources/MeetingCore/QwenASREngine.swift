import Foundation
import CryptoKit
import CSherpaBridge

public enum QwenASRError: Error, Equatable, Sendable {
    case runtimeLoad(String), missingSymbol(String), runtimeVersion(String), nativeFailure(String)
    case invalidConfiguration, modelFile(String), modelHash(String)
    case invalidPCM, unsupportedSampleRate(Int), audioTooLong, busy, invalidWAV
}

public struct QwenASRConfiguration: Sendable {
    public static let requiredFiles = ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx", "tokenizer/vocab.json", "tokenizer/merges.txt", "tokenizer/tokenizer_config.json"]
    public let modelDirectory: URL
    public let runtimePath: String
    public let revision: String
    public let threads: Int
    public let maximumSeconds: Int
    /// Caller supplies a trusted manifest. Matching hashes establish integrity against
    /// that manifest, not authenticity of an arbitrary caller-provided model.
    public let expectedSHA256: [String: String]?
    public init(modelDirectory: URL, runtimePath: String, revision: String, threads: Int = 4,
                maximumSeconds: Int = 30, expectedSHA256: [String: String]? = nil) {
        self.modelDirectory = modelDirectory; self.runtimePath = runtimePath; self.revision = revision
        self.threads = threads; self.maximumSeconds = maximumSeconds; self.expectedSHA256 = expectedSHA256
    }
    fileprivate func validateConfiguration() throws {
        guard !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !revision.contains("\0"), runtimePath.hasPrefix("/"), !runtimePath.contains("\0"),
              modelDirectory.isFileURL, !modelDirectory.path.contains("\0"),
              (1...8).contains(threads), (1...120).contains(maximumSeconds) else { throw QwenASRError.invalidConfiguration }
    }
    public func validateModel() throws {
        try validateConfiguration()
        for file in Self.requiredFiles {
            let url = modelDirectory.appendingPathComponent(file)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else { throw QwenASRError.modelFile(file) }
            if let manifest = expectedSHA256 {
                guard let expected = manifest[file], expected.count == 64,
                      expected.allSatisfy({ $0.isHexDigit }), try Self.sha256(url) == expected.lowercased() else { throw QwenASRError.modelHash(file) }
            }
        }
    }
    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct QwenASRResult: Codable, Sendable {
    public let text: String
    public let modelDirectory: String
    public let revision: String
    public let runtimePath: String
    public let runtimeVersion: String
    public let elapsedSeconds: Double
    public let sampleCount: Int
    public let sampleRate: Int
    public let integrityManifestVerified: Bool
    /// Optional for backward-compatible decoding of previously exported results.
    public let reusedRecognizer: Bool?
    public let loadSeconds: Double?
    public let decodeSeconds: Double?
}

private final class QwenCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func check() throws { if isCancelled() { throw CancellationError() } }
}

/// One bounded job per instance. Loading and decoding run on a dedicated serial queue.
/// The native C API cannot interrupt a running load/decode call. Cancellation is checked
/// around native work; the task completes only after the call returns and resources free.
/// PCM input must already be normalized Float, 16 kHz, mono; no implicit resampling.
public final class QwenASREngine: @unchecked Sendable {
    private let configuration: QwenASRConfiguration
    private let queue = DispatchQueue(label: "MeetingMac.QwenASR", qos: .userInitiated)
    private let lock = NSLock()
    private var running = false
    private var activeCancellation: QwenCancellation?
    private var shuttingDown = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    // Native work uses the serial queue except final idle deinit. Queued operations own self;
    // deinit therefore cannot run concurrently with native work (including on this queue).
    private var native: OpaquePointer?
    // Keep native configuration strings alive with their recognizer, including
    // runtimes that borrow path pointers after create returns.
    private var nativePaths: [UnsafeMutablePointer<CChar>?] = []
    private struct FileSignature: Equatable {
        let size: Int
        let modified: Date
        let resolvedPath: String
    }
    private var signatures: [String: FileSignature]?
    public init(configuration: QwenASRConfiguration) { self.configuration = configuration }
    deinit { cleanup() }
    private func cleanup() {
        if let native { mm_qwen_destroy(native) }
        native = nil; signatures = nil
        nativePaths.forEach { free($0) }; nativePaths = []
    }
    /// Cancels the active job, waits for any uninterruptible native call to return,
    /// then releases the resident runtime. Concurrent shutdown calls share that drain.
    /// New jobs are rejected as busy until the drain completes; later jobs reload
    /// exactly the original immutable configuration. Cancelling shutdown's caller
    /// does not abandon resource cleanup.
    public func shutdown() async throws {
        await withCheckedContinuation { continuation in
            lock.lock()
            shutdownWaiters.append(continuation)
            if shuttingDown { lock.unlock(); return }
            shuttingDown = true
            activeCancellation?.cancel()
            queue.async {
                self.cleanup()
                self.lock.lock()
                let waiters = self.shutdownWaiters
                self.shutdownWaiters = []
                self.shuttingDown = false
                self.lock.unlock()
                waiters.forEach { $0.resume() }
            }
            lock.unlock()
        }
    }
    private func enqueue(_ cancellation: QwenCancellation, operation: @escaping @Sendable () -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !running && !shuttingDown else { throw QwenASRError.busy }
        running = true; activeCancellation = cancellation
        // Admission and enqueue are atomic with shutdown; its drain cannot overtake
        // an admitted job before that job has reached the serial queue.
        queue.async(execute: operation)
    }
    private func release(_ cancellation: QwenCancellation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let cancelled = cancellation.isCancelled()
        running = false; activeCancellation = nil
        return cancelled
    }
    public static func validatePCM(_ samples: [Float], sampleRate: Int, maximumSeconds: Int = 30) throws {
        guard sampleRate == 16000 else { throw QwenASRError.unsupportedSampleRate(sampleRate) }
        guard (1...120).contains(maximumSeconds) else { throw QwenASRError.invalidConfiguration }
        guard samples.count <= 16000 * maximumSeconds else { throw QwenASRError.audioTooLong }
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw QwenASRError.invalidPCM }
    }
    private static func error(_ code: Int32, _ message: String) -> QwenASRError {
        switch code {
        case 1: return .runtimeLoad(message)
        case 2: return .missingSymbol(message)
        case 3: return .runtimeVersion(message)
        case 4: return .invalidConfiguration
        default: return .nativeFailure(message)
        }
    }
    /// Symbol/version probe only: this does not claim successful model initialization.
    public static func probeRuntime(path: String) throws -> String {
        var message = [CChar](repeating: 0, count: 2048)
        let code = path.withCString { mm_qwen_probe($0, &message, Int32(message.count)) }
        guard code == 0 else { throw error(code, String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
        return "1.13.7"
    }
    public func transcribe(samples: [Float], sampleRate: Int) async throws -> QwenASRResult {
        try Task.checkCancellation()
        try Self.validatePCM(samples, sampleRate: sampleRate, maximumSeconds: configuration.maximumSeconds)
        let cancellation = QwenCancellation()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { cancellation.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    try enqueue(cancellation) {
                        var result = Result {
                            do { return try self.run(samples: samples, cancellation: cancellation) }
                            catch {
                                // A cancelled native job may have touched internal caches.
                                // Always unload on cancellation/failure rather than reuse
                                // a recognizer whose state cannot be proved healthy.
                                self.cleanup()
                                try cancellation.check()
                                throw error
                            }
                        }
                        if self.release(cancellation) {
                            self.cleanup()
                            result = .failure(CancellationError())
                        }
                        continuation.resume(with: result)
                    }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { cancellation.cancel() }
    }
    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
    private func currentSignatures() throws -> [String: FileSignature] {
        var result: [String: FileSignature] = [:]
        for file in QwenASRConfiguration.requiredFiles {
            let url = configuration.modelDirectory.appendingPathComponent(file)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true, let size = values?.fileSize, size > 0,
                  let modified = values?.contentModificationDate else { throw QwenASRError.modelFile(file) }
            result[file] = FileSignature(size: size, modified: modified, resolvedPath: url.resolvingSymlinksInPath().path)
        }
        return result
    }
    private func checkSignatures(_ expected: [String: FileSignature]) throws {
        let current = try currentSignatures()
        for file in QwenASRConfiguration.requiredFiles where current[file] != expected[file] {
            throw QwenASRError.modelFile(file)
        }
    }
    private func run(samples: [Float], cancellation: QwenCancellation) throws -> QwenASRResult {
        let clock = ContinuousClock()
        let start = clock.now
        let reused = native != nil
        var loadSeconds = 0.0
        try cancellation.check()
        try configuration.validateConfiguration()
        var code: Int32 = 0
        var message = [CChar](repeating: 0, count: 2048)
        if let signatures {
            // Metadata checks per clip; trusted SHA validation only on cold load.
            try checkSignatures(signatures)
        } else {
            let snapshot = try currentSignatures()
            try configuration.validateModel()
            try checkSignatures(snapshot)
            try cancellation.check()
            let paths = [configuration.runtimePath] + ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx", "tokenizer"].map { configuration.modelDirectory.appendingPathComponent($0).path }
            let strings = paths.map { strdup($0) }
            nativePaths = strings
            guard strings.allSatisfy({ $0 != nil }) else { throw QwenASRError.nativeFailure("Path allocation failed") }
            native = mm_qwen_create(strings[0], strings[1], strings[2], strings[3], strings[4], Int32(configuration.threads), &code, &message, Int32(message.count))
            try cancellation.check()
            guard native != nil else { throw Self.error(code, String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
            try checkSignatures(snapshot)
            signatures = snapshot
            loadSeconds = Self.seconds(start.duration(to: clock.now))
        }
        try cancellation.check()
        guard let native else { throw QwenASRError.nativeFailure("Resident recognizer unavailable") }
        let decodeStart = clock.now
        var output: UnsafeMutablePointer<CChar>?
        code = samples.withUnsafeBufferPointer { mm_qwen_decode(native, $0.baseAddress, Int32($0.count), &output, { context in
            guard let context else { return 0 }
            return Unmanaged<QwenCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled() ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque(), &message, Int32(message.count)) }
        defer { if let output { mm_qwen_free_text(output) } }
        try cancellation.check()
        guard code == 0, let output else { throw Self.error(code, String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
        return QwenASRResult(text: String(cString: output), modelDirectory: configuration.modelDirectory.path,
            revision: configuration.revision, runtimePath: configuration.runtimePath, runtimeVersion: "1.13.7",
            elapsedSeconds: Self.seconds(start.duration(to: clock.now)), sampleCount: samples.count, sampleRate: 16000,
            integrityManifestVerified: configuration.expectedSHA256 != nil,
            reusedRecognizer: reused, loadSeconds: loadSeconds,
            decodeSeconds: Self.seconds(decodeStart.duration(to: clock.now)))
    }
}

/// Strict RIFF/WAVE parser: PCM signed little-endian 16-bit, 16 kHz, one channel.
/// Unsupported encodings require explicit conversion before invoking this adapter.
public enum QwenPCM16WAV {
    public static func parse(_ data: Data) throws -> [Float] {
        let bytes = [UInt8](data)
        func text(_ offset: Int) -> String { String(bytes: bytes[offset..<offset+4], encoding: .ascii) ?? "" }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i+1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i+2) << 16 }
        guard bytes.count >= 12, text(0) == "RIFF", text(8) == "WAVE" else { throw QwenASRError.invalidWAV }
        let end = u32(4) + 8
        guard end == bytes.count else { throw QwenASRError.invalidWAV }
        var offset = 12, hasFormat = false, pcm: [Float]?
        while offset < end {
            guard offset + 8 <= end else { throw QwenASRError.invalidWAV }
            let kind = text(offset), length = u32(offset + 4), start = offset + 8
            guard length <= end - start else { throw QwenASRError.invalidWAV }
            if kind == "fmt " {
                guard !hasFormat, length >= 16, u16(start) == 1, u16(start+2) == 1,
                      u32(start+4) == 16000, u32(start+8) == 32000, u16(start+12) == 2,
                      u16(start+14) == 16 else { throw QwenASRError.invalidWAV }
                hasFormat = true
            } else if kind == "data" {
                guard pcm == nil, length > 0, length % 2 == 0, length <= 16000 * 120 * 2 else { throw QwenASRError.invalidWAV }
                pcm = stride(from: start, to: start + length, by: 2).map { Float(Int16(bitPattern: UInt16(u16($0)))) / 32768 }
            }
            offset = start + length + length % 2
            guard offset <= end else { throw QwenASRError.invalidWAV }
        }
        guard hasFormat, let pcm else { throw QwenASRError.invalidWAV }; return pcm
    }
}
