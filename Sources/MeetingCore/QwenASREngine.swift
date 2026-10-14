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
    public func validateModel() throws {
        guard !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !revision.contains("\0"), runtimePath.hasPrefix("/"), !runtimePath.contains("\0"),
              modelDirectory.isFileURL, !modelDirectory.path.contains("\0"),
              (1...8).contains(threads), (1...120).contains(maximumSeconds) else { throw QwenASRError.invalidConfiguration }
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
    public init(configuration: QwenASRConfiguration) { self.configuration = configuration }
    private func reserve() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { throw QwenASRError.busy }; running = true
    }
    private func release() { lock.lock(); running = false; lock.unlock() }
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
        try reserve()
        let cancellation = QwenCancellation()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { cancellation.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    let result = Result { try self.run(samples: samples, cancellation: cancellation) }
                    self.release()
                    continuation.resume(with: result)
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    private func run(samples: [Float], cancellation: QwenCancellation) throws -> QwenASRResult {
        let start = Date()
        try cancellation.check()
        try configuration.validateModel()
        try cancellation.check()
        var code: Int32 = 0
        var message = [CChar](repeating: 0, count: 2048)
        let paths = [configuration.runtimePath] + ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx", "tokenizer"].map { configuration.modelDirectory.appendingPathComponent($0).path }
        let strings = paths.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { throw QwenASRError.nativeFailure("Path allocation failed") }
        let native = mm_qwen_create(strings[0], strings[1], strings[2], strings[3], strings[4], Int32(configuration.threads), &code, &message, Int32(message.count))
        defer { if let native { mm_qwen_destroy(native) } }
        try cancellation.check()
        guard let native else { throw Self.error(code, String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
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
            elapsedSeconds: Date().timeIntervalSince(start), sampleCount: samples.count, sampleRate: 16000,
            integrityManifestVerified: configuration.expectedSHA256 != nil)
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
