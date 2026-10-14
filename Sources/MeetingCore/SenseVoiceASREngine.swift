import Foundation
import CryptoKit
import CSherpaBridge

public enum SenseVoiceASRError: Error, Equatable, Sendable {
    case runtimeLoad(String), missingSymbol(String), runtimeVersion(String), nativeFailure(String)
    case invalidConfiguration, modelFile(String), modelHash(String)
    case invalidPCM, unsupportedSampleRate(Int), audioTooLong, busy
}

public struct SenseVoiceASRConfiguration: Sendable {
    public static let requiredFiles = ["model.int8.onnx", "tokens.txt"]
    public let modelDirectory: URL
    public let runtimePath: String
    public let revision: String
    public let threads: Int
    public let language: String
    public let useITN: Bool
    public let maximumSeconds: Int
    /// Caller supplies a trusted manifest. Matching hashes establish integrity against
    /// that manifest, not authenticity of an arbitrary caller-provided model.
    public let expectedSHA256: [String: String]?
    public init(modelDirectory: URL, runtimePath: String, revision: String, threads: Int = 4,
                maximumSeconds: Int = 30, language: String = "auto", useITN: Bool = true, expectedSHA256: [String: String]? = nil) {
        self.modelDirectory = modelDirectory; self.runtimePath = runtimePath; self.revision = revision
        self.language = language; self.useITN = useITN
        self.threads = threads; self.maximumSeconds = maximumSeconds; self.expectedSHA256 = expectedSHA256
    }
    fileprivate func validateConfiguration() throws {
        guard !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !revision.contains("\0"), runtimePath.hasPrefix("/"), !runtimePath.contains("\0"),
              modelDirectory.isFileURL, !modelDirectory.path.contains("\0"),
              ["auto", "zh", "en", "ja", "ko", "yue"].contains(language), (1...8).contains(threads), (1...120).contains(maximumSeconds) else { throw SenseVoiceASRError.invalidConfiguration }
    }
    public func validateModel() throws {
        try validateConfiguration()
        for file in Self.requiredFiles {
            let url = modelDirectory.appendingPathComponent(file)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else { throw SenseVoiceASRError.modelFile(file) }
            if let manifest = expectedSHA256 {
                guard let expected = manifest[file], expected.count == 64,
                      expected.allSatisfy({ $0.isHexDigit }), try Self.sha256(url) == expected.lowercased() else { throw SenseVoiceASRError.modelHash(file) }
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

public struct SenseVoiceASRResult: Codable, Sendable {
    public let text: String
    public let language: String
    public let useITN: Bool
    public let modelDirectory: String
    public let revision: String
    public let runtimePath: String
    public let runtimeVersion: String
    public let elapsedSeconds: Double
    public let sampleCount: Int
    public let sampleRate: Int
    public let integrityManifestVerified: Bool
    /// Phase timings distinguish cold loading from resident decode work.
    public let reusedRecognizer: Bool?
    public let loadSeconds: Double?
    public let decodeSeconds: Double?
}

private final class SenseVoiceCancellation: @unchecked Sendable {
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
public final class SenseVoiceASREngine: @unchecked Sendable {
    private let configuration: SenseVoiceASRConfiguration
    private let queue = DispatchQueue(label: "MeetingMac.SenseVoiceASR", qos: .userInitiated)
    private let lock = NSLock()
    private var running = false
    private var activeCancellation: SenseVoiceCancellation?
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
    public init(configuration: SenseVoiceASRConfiguration) { self.configuration = configuration }
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
    private func enqueue(_ cancellation: SenseVoiceCancellation, operation: @escaping @Sendable () -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !running && !shuttingDown else { throw SenseVoiceASRError.busy }
        running = true; activeCancellation = cancellation
        // Admission and enqueue are atomic with shutdown; its drain cannot overtake
        // an admitted job before that job has reached the serial queue.
        queue.async(execute: operation)
    }
    private func release(_ cancellation: SenseVoiceCancellation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let cancelled = cancellation.isCancelled()
        running = false; activeCancellation = nil
        return cancelled
    }
    public static func validatePCM(_ samples: [Float], sampleRate: Int, maximumSeconds: Int = 30) throws {
        guard sampleRate == 16000 else { throw SenseVoiceASRError.unsupportedSampleRate(sampleRate) }
        guard (1...120).contains(maximumSeconds) else { throw SenseVoiceASRError.invalidConfiguration }
        guard samples.count <= 16000 * maximumSeconds else { throw SenseVoiceASRError.audioTooLong }
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw SenseVoiceASRError.invalidPCM }
    }
    private static func error(_ code: Int32, _ message: String) -> SenseVoiceASRError {
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
    public func transcribe(samples: [Float], sampleRate: Int) async throws -> SenseVoiceASRResult {
        try Task.checkCancellation()
        try Self.validatePCM(samples, sampleRate: sampleRate, maximumSeconds: configuration.maximumSeconds)
        let cancellation = SenseVoiceCancellation()
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
        for file in SenseVoiceASRConfiguration.requiredFiles {
            let url = configuration.modelDirectory.appendingPathComponent(file)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true, let size = values?.fileSize, size > 0,
                  let modified = values?.contentModificationDate else { throw SenseVoiceASRError.modelFile(file) }
            result[file] = FileSignature(size: size, modified: modified, resolvedPath: url.resolvingSymlinksInPath().path)
        }
        return result
    }
    private func checkSignatures(_ expected: [String: FileSignature]) throws {
        let current = try currentSignatures()
        for file in SenseVoiceASRConfiguration.requiredFiles where current[file] != expected[file] {
            throw SenseVoiceASRError.modelFile(file)
        }
    }
    private func run(samples: [Float], cancellation: SenseVoiceCancellation) throws -> SenseVoiceASRResult {
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
            let paths = [configuration.runtimePath] + ["model.int8.onnx", "tokens.txt"].map { configuration.modelDirectory.appendingPathComponent($0).path }
            let strings = (paths + [configuration.language]).map { strdup($0) }
            nativePaths = strings
            guard strings.allSatisfy({ $0 != nil }) else { throw SenseVoiceASRError.nativeFailure("Path allocation failed") }
            native = mm_sensevoice_create(strings[0], strings[1], strings[2], strings[3], configuration.useITN ? 1 : 0, Int32(configuration.threads), &code, &message, Int32(message.count))
            try cancellation.check()
            guard native != nil else { throw Self.error(code, String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
            try checkSignatures(snapshot)
            signatures = snapshot
            loadSeconds = Self.seconds(start.duration(to: clock.now))
        }
        try cancellation.check()
        guard let native else { throw SenseVoiceASRError.nativeFailure("Resident recognizer unavailable") }
        let decodeStart = clock.now
        var output: UnsafeMutablePointer<CChar>?
        code = samples.withUnsafeBufferPointer { mm_qwen_decode(native, $0.baseAddress, Int32($0.count), &output, { context in
            guard let context else { return 0 }
            return Unmanaged<SenseVoiceCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled() ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque(), &message, Int32(message.count)) }
        defer { if let output { mm_qwen_free_text(output) } }
        try cancellation.check()
        guard code == 0, let output else { throw Self.error(code, String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
        return SenseVoiceASRResult(text: String(cString: output), language: configuration.language, useITN: configuration.useITN, modelDirectory: configuration.modelDirectory.path,
            revision: configuration.revision, runtimePath: configuration.runtimePath, runtimeVersion: "1.13.7",
            elapsedSeconds: Self.seconds(start.duration(to: clock.now)), sampleCount: samples.count, sampleRate: 16000,
            integrityManifestVerified: configuration.expectedSHA256 != nil,
            reusedRecognizer: reused, loadSeconds: loadSeconds,
            decodeSeconds: Self.seconds(decodeStart.duration(to: clock.now)))
    }
}

