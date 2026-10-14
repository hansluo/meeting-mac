import Foundation
import Observation

public struct TranscriptionConfiguration: Codable, Equatable, Sendable {
    public enum Engine: String, Codable, CaseIterable, Sendable { case qwen = "Qwen", funASR = "FunASR" }
    public var engine: Engine = .qwen
    public var qwenModel = ""
    public var qwenRuntime = ""
    public var qwenRevision = ""
    public var python = ""
    public var worker = ""
    public var funModel = ""
    public var checkpoint = "model.pt"
    public var funRevision = ""
    public init() {}
    public var missingConfiguration: String? {
        let required: [(String, String)] = engine == .qwen
            ? [(qwenModel, "Qwen 模型目录"), (qwenRuntime, "sherpa 运行库 dylib"), (qwenRevision, "Qwen 模型版本")]
            : [(python, "Python 可执行文件"), (worker, "FunASR worker 脚本"), (funModel, "FunASR 模型目录"), (checkpoint, "checkpoint 文件名"), (funRevision, "FunASR 模型版本")]
        let missing = required.filter { $0.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.1)
        return missing.isEmpty ? nil : "请在模型设置中填写：" + missing.joined(separator: "、")
    }
}

public struct TranscriptionOutput: Sendable {
    public let text: String
    public let provenance: String
    public init(text: String, provenance: String) { self.text = text; self.provenance = provenance }
}

/// Owns one bounded operation, including its resource drain. Cancellation suppresses
/// publication immediately but admission stays closed until the operation cleans up.
@MainActor @Observable public final class TranscriptionJob {
    public private(set) var isBusy = false
    public private(set) var status = "选择音频后开始转写"
    public private(set) var result: TranscriptionOutput?
    public private(set) var resultAudioURL: URL?
    public private(set) var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelled = false
    public init() {}
    @discardableResult public func start(configuration: TranscriptionConfiguration, audioURL: URL,
        operation: @escaping @Sendable (TranscriptionConfiguration, URL) async throws -> TranscriptionOutput = LocalTranscription.run) -> Bool {
        guard !isBusy else { return false }
        isBusy = true; cancelled = false; errorMessage = nil; status = "正在校验音频、加载模型并转写…"
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<TranscriptionOutput, Error>
            do { outcome = .success(try await operation(configuration, audioURL)) }
            catch { outcome = .failure(error) }
            await self?.finish(outcome, audioURL: audioURL)
        }
        return true
    }
    private func finish(_ outcome: Result<TranscriptionOutput, Error>, audioURL: URL) {
        defer { isBusy = false; task = nil }
        if cancelled { status = "已取消"; return }
        switch outcome {
        case .success(let output):
            result = output; resultAudioURL = audioURL
            status = output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未识别到语音" : "转写完成"
        case .failure(let error):
            errorMessage = LocalTranscription.message(for: error); status = "转写失败"
        }
    }
    public func cancel() {
        guard isBusy else { return }
        cancelled = true; status = "正在取消并释放模型，请稍候…"; task?.cancel()
    }
    public func waitUntilIdle() async { await task?.value }
    public func shutdown() async { cancel(); await waitUntilIdle() }
}

public enum LocalTranscription {
    /// Called by the detached job, never by a view's main-actor file-reading path.
    public static func run(_ configuration: TranscriptionConfiguration, _ url: URL) async throws -> TranscriptionOutput {
        if let missing = configuration.missingConfiguration { throw ConfigurationError.missing(missing) }
        try Task.checkCancellation()
        let paths = configuration.engine == .qwen ? [configuration.qwenModel, configuration.qwenRuntime]
            : [configuration.python, configuration.worker, configuration.funModel]
        guard url.isFileURL, paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
            throw ConfigurationError.missing("音频、模型和运行时必须使用本地绝对路径，请重新浏览选择。")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw QwenASRError.invalidWAV }
        guard let size = values.fileSize, size <= 1_000_000 else { throw QwenASRError.audioTooLong }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_000_001) ?? Data()
        guard data.count <= 1_000_000 else { throw QwenASRError.audioTooLong }
        let samples = try QwenPCM16WAV.parse(data)
        try QwenASREngine.validatePCM(samples, sampleRate: 16000, maximumSeconds: 30)
        try Task.checkCancellation()
        switch configuration.engine {
        case .qwen:
            let engine = QwenASREngine(configuration: .init(modelDirectory: URL(fileURLWithPath: configuration.qwenModel), runtimePath: configuration.qwenRuntime, revision: configuration.qwenRevision))
            let outcome: Result<QwenASRResult, Error>
            do { outcome = .success(try await engine.transcribe(samples: samples, sampleRate: 16000)) }
            catch { outcome = .failure(error) }
            try await engine.shutdown()
            let r = try outcome.get()
            return .init(text: r.text, provenance: "Qwen · sherpa-onnx \(r.runtimeVersion) · \(r.revision)\n模型：\(r.modelDirectory)\n运行库：\(r.runtimePath)\n音频：\(r.sampleCount) samples / \(r.sampleRate) Hz · 耗时 \(String(format: "%.2f", r.elapsedSeconds)) 秒\n版本由用户声明；未进行模型哈希验证。")
        case .funASR:
            // Freeze the validated bytes: the selected file can change while Python loads.
            let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let jobDirectory = cache.appendingPathComponent("com.hansluo.meetingmac/jobs/" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: jobDirectory) }
            let snapshotURL = jobDirectory.appendingPathComponent("audio.wav")
            try data.write(to: snapshotURL, options: .atomic)
            let worker = FunASRWorker(configuration: .init(pythonExecutable: URL(fileURLWithPath: configuration.python), workerScript: URL(fileURLWithPath: configuration.worker), modelDirectory: URL(fileURLWithPath: configuration.funModel), checkpoint: configuration.checkpoint, revision: configuration.funRevision))
            let outcome: Result<FunASRResult, Error>
            do { outcome = .success(try await worker.transcribe(wavURL: snapshotURL)) }
            catch { outcome = .failure(error) }
            // transcribe only returns after its cancellation/reap releases busy.
            // Detached cleanup is uncancelled, so shutdown cannot skip the drain.
            try await Task.detached { try await worker.shutdown() }.value
            let r = try outcome.get()
            return .init(text: r.text, provenance: "FunASR · \(r.revision) · \(r.checkpoint)\n模型：\(r.modelDirectory.path)\nPython：\(configuration.python)\nWorker：\(configuration.worker)\n音频：\(r.sampleCount) samples / 16000 Hz\n版本由用户声明；未进行模型哈希验证。")
        }
    }
    private enum ConfigurationError: Error { case missing(String) }
    public static func message(for error: Error) -> String {
        if case ConfigurationError.missing(let message) = error { return message }
        if let error = error as? QwenASRError {
            switch error {
            case .invalidWAV, .invalidPCM, .unsupportedSampleRate: return "音频格式不支持。请选择 PCM16、16 kHz、单声道 WAV；其他格式请先转换。"
            case .audioTooLong: return "音频超出本版限制。请选择不超过 30 秒的 PCM16 / 16 kHz / 单声道 WAV。"
            case .modelFile(let file), .modelHash(let file): return "模型文件缺失或校验失败：\(file)。请检查模型目录。"
            default: return "Qwen 运行失败：\(error)。请检查模型目录、版本与 sherpa-onnx 1.13.7 运行库。"
            }
        }
        if let error = error as? FunASRWorkerError { return "FunASR 运行失败：\(error)。请检查 Python 环境、worker、模型目录、checkpoint 与版本。" }
        return "无法完成转写：\(error.localizedDescription)"
    }
}
