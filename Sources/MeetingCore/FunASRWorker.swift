import Foundation
import Darwin
import CoreFoundation

public enum FunASRWorkerError: Error, Equatable, Sendable {
    case invalidConfiguration, runtimeUnavailable, invalidAudio, busy, timedOut, cancelled
    case protocolViolation, workerExited, backend(String)
}
public struct FunASRConfiguration: Sendable {
    public let pythonExecutable: URL
    public let workerScript: URL
    public let modelDirectory: URL
    public let checkpoint: String
    public let revision: String
    public let startupTimeout: Double
    public let requestTimeout: Double
    public init(pythonExecutable: URL, workerScript: URL, modelDirectory: URL, checkpoint: String, revision: String, startupTimeout: Double = 30, requestTimeout: Double = 120) {
        self.pythonExecutable = pythonExecutable; self.workerScript = workerScript; self.modelDirectory = modelDirectory
        self.checkpoint = checkpoint; self.revision = revision; self.startupTimeout = startupTimeout; self.requestTimeout = requestTimeout
    }
}
public struct FunASRCapabilities: Sendable {
    public let batch = true
    public let nativeStreaming = false
    public let hotwords = false
    public let wordAlignment = false
    public let diarization = false
}
public struct FunASRProbe: Sendable {
    public let capabilities = FunASRCapabilities()
    public let packageVersion: String
    public let device: String
    public let modelLoaded: Bool
    public let asrVerified: Bool
}
public struct FunASRResult: Sendable {
    public let text: String
    public let rawText: String
    public let sampleCount: Int
    /// Actual JSON backend metadata, without fabricated alignment or speaker labels.
    public let backendFields: Data
    public let modelDirectory: URL
    public let checkpoint: String
    public let revision: String
}
private final class FunASRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    func bind(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }; self.process = process
        if cancelled { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; throw FunASRWorkerError.cancelled }
    }
    func finish() throws { lock.lock(); defer { lock.unlock() }; process = nil; if cancelled { throw FunASRWorkerError.cancelled } }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw FunASRWorkerError.cancelled } }
}
/// Resident local subprocess. A single bounded job runs at a time. Cancel/failure kills
/// and reaps this worker; the next job creates a fresh generation with the same config.
public final class FunASRWorker: @unchecked Sendable {
    private let configuration: FunASRConfiguration
    private let queue = DispatchQueue(label:"MeetingMac.FunASR", qos:.userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var loaded = false
    private var exitSignal: DispatchSemaphore?
    private var generation = UUID()
    public init(configuration: FunASRConfiguration) { self.configuration = configuration }
    deinit { cleanup() }
    public var hasRunningProcess: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true }
    public var processIdentifier: Int32? { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true ? process?.processIdentifier : nil }
    private func reserve() throws { lock.lock(); defer { lock.unlock() }; guard !busy else { throw FunASRWorkerError.busy }; busy = true }
    private func release() { lock.lock(); busy = false; lock.unlock() }
    public func shutdown() async throws { try await perform { _ in self.cleanup() } }
    public func probeRuntime() async throws -> FunASRProbe {
        try await perform { token in
            try self.start(token)
            let response = try self.request(["op":"probe"], expected:"probe", token:token)
            guard let version = response["package_version"] as? String, !version.isEmpty,
                  response["device"] as? String == "cpu",
                  ["model_loaded","asr_verified"].allSatisfy({ key in (response[key] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true }),
                  let modelLoaded = response["model_loaded"] as? Bool,
                  let verified = response["asr_verified"] as? Bool, !verified else { throw FunASRWorkerError.protocolViolation }
            return FunASRProbe(packageVersion:version, device:"cpu", modelLoaded:modelLoaded, asrVerified:verified)
        }
    }
    public func transcribe(wavURL: URL) async throws -> FunASRResult {
        try await perform { token in
            guard wavURL.isFileURL, let size = try? wavURL.resourceValues(forKeys:[.fileSizeKey]).fileSize, size <= 1_000_000,
                  let data = try? Data(contentsOf:wavURL), data.count <= 1_000_000,
                  let samples = try? QwenPCM16WAV.parse(data), (try? QwenASREngine.validatePCM(samples,sampleRate:16000,maximumSeconds:30)) != nil else { throw FunASRWorkerError.invalidAudio }
            try self.start(token)
            if !self.loaded {
                _ = try self.request(["op":"load", "model_dir":self.configuration.modelDirectory.path,"checkpoint":self.configuration.checkpoint,"revision":self.configuration.revision], expected:"ready",token:token)
                self.loaded = true
            }
            let result = try self.request(["op":"transcribe","audio_path":wavURL.path],expected:"result",token:token)
            guard let text = result["text"] as? String, let raw = result["raw_text"] as? String,
                  let count = result["sample_count"] as? Int, count == samples.count,
                  let fields = result["backend_fields"] as? [String:Any], JSONSerialization.isValidJSONObject(fields) else { throw FunASRWorkerError.protocolViolation }
            return FunASRResult(text:text,rawText:raw,sampleCount:count,backendFields:try JSONSerialization.data(withJSONObject:fields),modelDirectory:self.configuration.modelDirectory,checkpoint:self.configuration.checkpoint,revision:self.configuration.revision)
        }
    }
    private func perform<T: Sendable>(_ operation: @escaping @Sendable (FunASRCancellation) throws -> T) async throws -> T {
        if Task.isCancelled { throw FunASRWorkerError.cancelled }; try reserve()
        let token = FunASRCancellation()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { token.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    let result = Result { () throws -> T in
                        do { try token.check(); let value = try operation(token); try token.finish(); return value }
                        catch { self.cleanup(); try token.finish(); throw error }
                    }
                    self.release(); continuation.resume(with:result)
                }
            }
        } onCancel: { token.cancel() }
    }
    private func start(_ token: FunASRCancellation) throws {
        let c = configuration
        guard [c.pythonExecutable,c.workerScript,c.modelDirectory].allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.contains("\0") }),
              !c.revision.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, c.revision.count <= 256, !c.revision.contains("\0"),
              !c.checkpoint.isEmpty, !c.checkpoint.hasPrefix("/"), !c.checkpoint.split(separator:"/").contains(".."), !c.checkpoint.contains("\0"),
              c.startupTimeout.isFinite, c.requestTimeout.isFinite, c.startupTimeout > 0, c.requestTimeout > 0 else { throw FunASRWorkerError.invalidConfiguration }
        if let process, process.isRunning { try token.bind(process); return }
        cleanup()
        guard FileManager.default.isExecutableFile(atPath:c.pythonExecutable.path), FileManager.default.fileExists(atPath:c.workerScript.path) else { throw FunASRWorkerError.runtimeUnavailable }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        let exited = DispatchSemaphore(value:0)
        child.terminationHandler = { _ in exited.signal() }
        child.executableURL = c.pythonExecutable
        child.arguments = ["-u", c.workerScript.path, c.modelDirectory.path]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        var environment = ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "LANG":"en_US.UTF-8"]
        environment["HF_HUB_OFFLINE"] = "1"; environment["MODELSCOPE_OFFLINE"] = "1"; environment["PYTHONNOUSERSITE"] = "1"
        child.environment = environment
        do { try child.run() } catch { throw FunASRWorkerError.runtimeUnavailable }
        lock.lock(); process = child; lock.unlock()
        exitSignal = exited
        input = stdin; output = stdout; generation = UUID(); loaded = false
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw FunASRWorkerError.runtimeUnavailable }
        let fd = stdout.fileHandleForReading.fileDescriptor
        _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) | O_NONBLOCK)
        try token.bind(child)
        let ready = try read(deadline:ProcessInfo.processInfo.systemUptime + c.startupTimeout,token:token)
        guard ready["type"] as? String == "started", ready["job_id"] is NSNull else { throw FunASRWorkerError.protocolViolation }
    }
    private func request(_ fields:[String:Any], expected:String, token:FunASRCancellation) throws -> [String:Any] {
        let currentGeneration = generation, job = UUID().uuidString.lowercased()
        var request = fields; request["version"] = 1; request["job_id"] = job
        var data = try JSONSerialization.data(withJSONObject:request); data.append(10)
        guard data.count <= 4096, let input else { throw FunASRWorkerError.protocolViolation }
        // Input is capped at 4 KiB and below pipe capacity; private pipe is only written by this queue.
        do { try input.fileHandleForWriting.write(contentsOf:data) } catch { try token.check(); throw FunASRWorkerError.workerExited }
        let response = try read(deadline:ProcessInfo.processInfo.systemUptime + configuration.requestTimeout,token:token)
        try token.check()
        guard generation == currentGeneration, response["job_id"] as? String == job else { throw FunASRWorkerError.protocolViolation }
        if response["type"] as? String == "error" {
            let safeCodes = ["runtime_unavailable","invalid_configuration","missing_checkpoint","missing_configuration","model_load_failed","model_not_loaded","invalid_audio","invalid_backend_result","transcription_failed","unsupported_operation","worker_failed","result_too_large"]
            guard let code = response["code"] as? String, safeCodes.contains(code) else { throw FunASRWorkerError.protocolViolation }
            throw FunASRWorkerError.backend(code)
        }
        guard response["type"] as? String == expected else { throw FunASRWorkerError.protocolViolation }; return response
    }
    private func read(deadline:Double, token:FunASRCancellation) throws -> [String:Any] {
        guard let output else { throw FunASRWorkerError.workerExited }
        let fd = output.fileHandleForReading.fileDescriptor
        while true {
            try token.check()
            if let newline = buffer.firstIndex(of:10) {
                guard newline <= 65536 else { throw FunASRWorkerError.protocolViolation }
                let line = buffer.prefix(upTo:newline); buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with:line), let value = object as? [String:Any],
                      let version = value["version"] as? Int, version == 1, (value["version"] as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true else { throw FunASRWorkerError.protocolViolation }
                return value
            }
            guard buffer.count <= 65536 else { throw FunASRWorkerError.protocolViolation }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw FunASRWorkerError.timedOut }
            var descriptor = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
            let status = poll(&descriptor,1,20)
            if status < 0 && errno != EINTR { throw FunASRWorkerError.workerExited }
            if status > 0 {
                var bytes = [UInt8](repeating:0,count:4096)
                let count = Darwin.read(fd,&bytes,bytes.count)
                if count > 0 { buffer.append(contentsOf:bytes.prefix(count)) }
                else if count == 0 { try token.check(); throw FunASRWorkerError.workerExited }
                else if errno != EAGAIN && errno != EINTR { throw FunASRWorkerError.workerExited }
            }
        }
    }
    private func cleanup() {
        lock.lock(); let child = process; process = nil; lock.unlock()
        if let child { if child.isRunning { kill(child.processIdentifier,SIGKILL) }; exitSignal?.wait() }
        try? input?.fileHandleForWriting.close(); try? output?.fileHandleForReading.close()
        exitSignal = nil
        input = nil; output = nil; buffer.removeAll(keepingCapacity:false); loaded = false
    }
}
