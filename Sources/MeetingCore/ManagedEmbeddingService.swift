import Foundation
import Darwin

/// Input identity/order stays with the caller; each result retains this exact input.
public enum EmbeddingInput: Equatable, Sendable {
    case query(String)
    case document(title: String, text: String)
    var formatted: String {
        switch self {
        case .query(let text): return "task: search result | query: " + text
        case .document(let title, let text): return "title: \(title) | text: \(text)"
        }
    }
    var valid: Bool {
        let text: String
        switch self { case .query(let value): text = value; case .document(_, let value): text = value }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && formatted.utf8.count <= 16000
    }
}
public struct EmbeddingResult: Sendable {
    public let input: EmbeddingInput
    public let vector: [Float]
    public let model: String
    public let checkpointSHA256: String
    public let runtimeRevision: String
    public let executionLocation: ExecutionLocation
}
public enum ManagedEmbeddingError: Error, Equatable, Sendable {
    case busy, invalidInput, assetsUnavailable, startupFailed, timedOut, helperExited
    case httpStatus(Int), invalidResponse, responseTooLarge, contextExceeded, transport
}

/// One owned offline helper, one admitted batch. Failed/cancelled work discards the helper.
/// A batch is at most 16 items; each item is independently tokenized and embedded.
public actor ManagedEmbeddingService {
    public static let model = "meeting-embeddinggemma300m"
    private let store: ManagedAssetStore
    private let timeout: TimeInterval
    private var helper: EmbeddingHelper?
    private var active: Task<([EmbeddingResult], EmbeddingHelper), Error>?
    private var activeID: UUID?
    private var shutdownID: UUID?
    private var closing = false
    private var shutdownDrain: Task<Void, Never>?
    public init(store: ManagedAssetStore = ManagedAssetStore(), timeout: TimeInterval = 120) {
        self.store = store
        self.timeout = timeout.isFinite ? min(300, max(0.1, timeout)) : 120
    }
    public func embed(_ inputs: [EmbeddingInput]) async throws -> [EmbeddingResult] {
        guard active == nil, !closing else { throw ManagedEmbeddingError.busy }
        guard !inputs.isEmpty, inputs.count <= 16, inputs.allSatisfy(\.valid), inputs.reduce(0, { $0 + $1.formatted.utf8.count }) <= 64000 else { throw ManagedEmbeddingError.invalidInput }
        let previous = helper, store = store
        helper = nil
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let task = Task.detached { () throws -> ([EmbeddingResult], EmbeddingHelper) in
            var worker = previous
            do {
                try Task.checkCancellation()
                if worker == nil { worker = try await EmbeddingHelper.start(store: store, deadline: deadline) }
                let owned = worker!
                var results: [EmbeddingResult] = []
                for input in inputs {
                    try Task.checkCancellation()
                    let vector = try await owned.embed(input.formatted, deadline: deadline)
                    results.append(EmbeddingResult(input: input, vector: vector, model: Self.model,
                        checkpointSHA256: owned.checkpointSHA256, runtimeRevision: owned.runtimeRevision, executionLocation: .onDevice))
                }
                try Task.checkCancellation()
                return (results, owned)
            } catch {
                await worker?.stop()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }
        let admission = UUID()
        active = task
        activeID = admission
        defer {
            if activeID == admission { active = nil; activeID = nil }
        }
        return try await withTaskCancellationHandler {
            let (result, owned) = try await task.value
            if closing || Task.isCancelled || task.isCancelled { await owned.stop(); throw CancellationError() }
            helper = owned
            return result
        } onCancel: { task.cancel() }
    }
    /// Cancels and drains the active request and reaps this service's child. Reusable afterward.
    public func shutdown() async {
        if let shutdownDrain, let shutdownID {
            let admitted = activeID
            await shutdownDrain.value
            finishShutdown(shutdownID, admitted: admitted)
            return
        }
        closing = true
        let identity = UUID(), admitted = activeID
        shutdownID = identity
        let current = active, idle = helper
        helper = nil
        current?.cancel()
        let drain = Task.detached {
            if let current, case .success((_, let owned)) = await current.result { await owned.stop() }
            await idle?.stop()
        }
        shutdownDrain = drain
        await drain.value
        finishShutdown(identity, admitted: admitted)
    }
    private func finishShutdown(_ identity: UUID, admitted: UUID?) {
        guard shutdownID == identity else { return }
        if activeID == admitted { active = nil; activeID = nil }
        closing = false
        shutdownDrain = nil
        shutdownID = nil
    }

}

/// Mutable lifecycle is exclusively held by the single admitted request/shutdown.
private final class EmbeddingHelper: @unchecked Sendable {
    let process: Process
    let directory: URL
    let baseURL: URL
    let key: String
    let checkpointSHA256: String
    let runtimeRevision: String
    private let cleanupLock = NSLock()
    private var cleanup: Task<Void, Never>?
    init(process: Process, directory: URL, port: UInt16, key: String, checkpointSHA256: String, runtimeRevision: String) {
        self.process = process; self.directory = directory; self.key = key
        self.checkpointSHA256 = checkpointSHA256; self.runtimeRevision = runtimeRevision
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }
    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: directory)
    }
    static func start(store: ManagedAssetStore, deadline: TimeInterval) async throws -> EmbeddingHelper {
        guard let model = try await store.resolved("embeddinggemma300m"),
              let runtime = try await store.resolved("llama-server-ollama0.40.4") else { throw ManagedEmbeddingError.assetsUnavailable }
        let definitions = try await store.embeddingDefinitions()
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw ManagedEmbeddingError.timedOut }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-embedding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let key = UUID().uuidString + UUID().uuidString
        let keyFile = directory.appendingPathComponent("api-key")
        do {
            try Data((key + "\n").utf8).write(to: keyFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
            let port = try availablePort()
            let process = Process()
            process.executableURL = runtime.appendingPathComponent("llama-server")
            process.arguments = ["--model", model.appendingPathComponent("model.gguf").path,
                "--alias", ManagedEmbeddingService.model, "--host", "127.0.0.1", "--port", String(port),
                "--api-key-file", keyFile.path, "--offline", "--no-webui", "--embedding",
                "--ctx-size", "2048", "--batch-size", "2048", "--ubatch-size", "2048", "--parallel", "1", "--threads", "4", "--n-gpu-layers", "0"]
            // Explicit allowlist. No HOME mutation, inherited cloud key, proxy, or model override.
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            let owned = EmbeddingHelper(process: process, directory: directory, port: port, key: key,
                checkpointSHA256: definitions.0, runtimeRevision: definitions.1)
            do {
                try process.run()
                while true {
                    try Task.checkCancellation()
                    guard process.isRunning else { throw ManagedEmbeddingError.helperExited }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw ManagedEmbeddingError.timedOut }
                    do {
                        // A daemon which ignores authentication cannot satisfy readiness,
                        // even if a bind race exposes the same model alias on this port.
                        _ = try await owned.request("v1/models", body: nil,
                            deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 0.5), authenticated: false, expectedStatus: 401)
                        let data = try await owned.request("v1/models", body: nil, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 0.5))
                        struct Models: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
                        guard let models = try? JSONDecoder().decode(Models.self, from: data), models.data.map(\.id) == [ManagedEmbeddingService.model] else { throw ManagedEmbeddingError.invalidResponse }
                        return owned
                    } catch ManagedEmbeddingError.transport { }
                    catch ManagedEmbeddingError.timedOut { }
                    catch ManagedEmbeddingError.httpStatus(503) { }
                    try await Task.sleep(for: .milliseconds(40))
                }
            } catch {
                await owned.stop()
                if error is CancellationError || error is ManagedEmbeddingError { throw error }
                throw ManagedEmbeddingError.startupFailed
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if error is CancellationError || error is ManagedEmbeddingError { throw error }
            throw ManagedEmbeddingError.startupFailed
        }
    }
    func embed(_ text: String, deadline: TimeInterval) async throws -> [Float] {
        // Native /tokenize uses the same tokenizer. Reserve two additional boundary tokens
        // beyond add_special=true, so no request can rely on server-side truncation.
        let tokensData = try await request("tokenize", body: ["content": text, "add_special": true], deadline: deadline)
        struct Tokens: Decodable { let tokens: [Int] }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: tokensData), !tokens.tokens.isEmpty else { throw ManagedEmbeddingError.invalidResponse }
        guard tokens.tokens.count <= 2046 else { throw ManagedEmbeddingError.contextExceeded }
        let data = try await request("v1/embeddings", body: ["model": ManagedEmbeddingService.model, "input": [text], "encoding_format": "float"], deadline: deadline)
        struct Response: Decodable {
            struct Item: Decodable { let index: Int; let embedding: [Double] }
            let model: String; let data: [Item]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.model == ManagedEmbeddingService.model,
              response.data.count == 1, response.data[0].index == 0 else { throw ManagedEmbeddingError.invalidResponse }
        let values = response.data[0].embedding
        guard values.count == 768, values.allSatisfy(\.isFinite) else { throw ManagedEmbeddingError.invalidResponse }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-12 else { throw ManagedEmbeddingError.invalidResponse }
        let vector = values.map { Float($0 / norm) }
        guard vector.allSatisfy(\.isFinite) else { throw ManagedEmbeddingError.invalidResponse }
        return vector
    }
    func request(_ path: String, body: [String: Any]?, deadline: TimeInterval, authenticated: Bool = true, expectedStatus: Int = 200) async throws -> Data {
        try Task.checkCancellation()
        guard process.isRunning else { throw ManagedEmbeddingError.helperExited }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw ManagedEmbeddingError.timedOut }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: remaining)
        if authenticated { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false; config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = remaining; config.timeoutIntervalForResource = remaining
        let session = URLSession(configuration: config, delegate: EmbeddingRedirectRejection(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ManagedEmbeddingError.invalidResponse }
            guard response.statusCode == expectedStatus else { throw ManagedEmbeddingError.httpStatus(response.statusCode) }
            guard response.expectedContentLength <= 262144 else { throw ManagedEmbeddingError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 262144 else { throw ManagedEmbeddingError.responseTooLarge }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw ManagedEmbeddingError.timedOut }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard process.isRunning else { throw ManagedEmbeddingError.helperExited }
            return data
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? ManagedEmbeddingError { throw error }
            if (error as? URLError)?.code == .timedOut { throw ManagedEmbeddingError.timedOut }
            throw ManagedEmbeddingError.transport
        }
    }
    func stop() async {
        // A separate uncancelled cleanup task prevents cancellation from turning sleeps
        // into a busy loop, and concurrent shutdown callers share the same drain.
        let drain = cleanupLock.withLock { () -> Task<Void, Never> in
            if let cleanup { return cleanup }
            let task = Task.detached { [self] in
                if process.isRunning { process.terminate() }
                let grace = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning, ProcessInfo.processInfo.systemUptime < grace { try? await Task.sleep(for: .milliseconds(10)) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                let reap = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning, ProcessInfo.processInfo.systemUptime < reap { try? await Task.sleep(for: .milliseconds(10)) }
                try? FileManager.default.removeItem(at: directory)
            }
            cleanup = task
            return task
        }
        await drain.value
    }
    static func availablePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw ManagedEmbeddingError.startupFailed }
        defer { close(socket) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw ManagedEmbeddingError.startupFailed }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &size) } }
        guard result == 0 else { throw ManagedEmbeddingError.startupFailed }
        return UInt16(bigEndian: address.sin_port)
    }
}
private final class EmbeddingRedirectRejection: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
