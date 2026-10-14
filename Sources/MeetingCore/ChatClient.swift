import Foundation

public enum ChatClientError: Error, Sendable, Equatable {
    case invalidEndpoint
    case onDeviceEndpointRequired
    case invalidTimeout
    case invalidParameters
    case unsupportedChatRoute
    case httpStatus(Int)
    case invalidResponse
    case redirectRejected
    case cancelled
    /// URL loading error code only. URLs, headers and server bodies are never retained.
    case transport(code: Int)
}

public struct ChatEndpoint: Sendable {
    public let chatURL: URL
    public let modelsURL: URL
    public let ollamaTagsURL: URL
    public let isLoopback: Bool

    /// A root URL defaults to /v1. A non-root path is already an API prefix.
    /// An explicit prefix is appended to the base path, without repeating its suffix.
    public init(baseURL: URL, apiPrefix: String? = nil) throws {
        guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw ChatClientError.invalidEndpoint
        }
        let basePath = parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var apiPath = basePath
        if let apiPrefix {
            guard !apiPrefix.contains("?"), !apiPrefix.contains("#"), !apiPrefix.contains(":") else {
                throw ChatClientError.invalidEndpoint
            }
            var prefixParts = URLComponents()
            prefixParts.path = apiPrefix
            let prefix = prefixParts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !prefix.isEmpty && apiPath != prefix && !apiPath.hasSuffix("/" + prefix) {
                apiPath = [apiPath, prefix].filter { !$0.isEmpty }.joined(separator: "/")
            }
        } else if apiPath.isEmpty { apiPath = "v1" }
        func url(_ path: String) throws -> URL {
            parts.percentEncodedPath = "/" + path
            guard let url = parts.url else { throw ChatClientError.invalidEndpoint }
            return url
        }
        chatURL = try url([apiPath, "chat/completions"].filter { !$0.isEmpty }.joined(separator: "/"))
        modelsURL = try url([apiPath, "models"].filter { !$0.isEmpty }.joined(separator: "/"))
        var nativePath = basePath.split(separator: "/").map(String.init)
        if nativePath.last == "v1" { nativePath.removeLast() }
        ollamaTagsURL = try url((nativePath + ["api/tags"]).joined(separator: "/"))
        isLoopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }
}

public struct ChatMessage: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) { self.role = role; self.content = content }
}
public enum ChatDiscoveryFormat: Sendable { case openAI, ollama }
public struct ChatUsage: Codable, Sendable, Equatable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", totalTokens = "total_tokens"
    }
}
public struct ChatResponse: Sendable, Equatable {
    public let content: String
    public let finishReason: String?
    public let model: String?
    public let usage: ChatUsage?
}
private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The test request and formal generation use this same non-streaming request path.
/// There is no discovery prerequisite and no profile/model fallback.
public final class ChatClient: @unchecked Sendable {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 60) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 300 else { throw ChatClientError.invalidTimeout }
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func discover(endpoint: ChatEndpoint, format: ChatDiscoveryFormat,
                         credential: String? = nil) async throws -> [String] {
        try checkCancellation()
        let url = format == .openAI ? endpoint.modelsURL : endpoint.ollamaTagsURL
        let data = try await send(url: url, credential: credential)
        do {
            switch format {
            case .openAI:
                return try JSONDecoder().decode(OpenAIModels.self, from: data).data.map { model in
                    guard !model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ChatClientError.invalidResponse
                    }
                    return model.id
                }
            case .ollama:
                return try JSONDecoder().decode(OllamaModels.self, from: data).models.map { model in
                    guard !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ChatClientError.invalidResponse
                    }
                    return model.name
                }
            }
        } catch { throw ChatClientError.invalidResponse }
    }

    public func generate(task: TaskRole, route: TaskRoute, profiles: [ProviderProfile], messages: [ChatMessage],
                         credential: String? = nil, apiPrefix: String? = nil, maxTokens: Int? = nil,
                         temperature: Double? = nil) async throws -> ChatResponse {
        try checkCancellation()
        // Resolve before endpoint handling, encoding, or network access.
        let profile = try RouteResolver.resolve(task: task, route: route, profiles: profiles)
        let chatTasks: Set<TaskRole> = [.qa, .summary, .noteEnhancement, .voiceInputCorrection, .questionDetection]
        guard profile.kind == .llm, chatTasks.contains(task) else { throw ChatClientError.unsupportedChatRoute }
        guard let baseURL = profile.baseURL else { throw ChatClientError.invalidEndpoint }
        let endpoint = try ChatEndpoint(baseURL: baseURL, apiPrefix: apiPrefix)
        if profile.executionLocation == .onDevice && !endpoint.isLoopback {
            throw ChatClientError.onDeviceEndpointRequired
        }
        guard let model = profile.modelID else { throw RouteError.modelNotSelected }
        guard !messages.isEmpty, maxTokens.map({ $0 > 0 }) ?? true,
              temperature.map({ $0.isFinite && $0 >= 0 && $0 <= 2 }) ?? true else {
            throw ChatClientError.invalidParameters
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(GenerationRequest(model: model, messages: messages,
                maxTokens: maxTokens, temperature: temperature))
        } catch { throw ChatClientError.invalidParameters }
        let data = try await send(url: endpoint.chatURL, credential: credential, body: body)
        do {
            let response = try JSONDecoder().decode(GenerationResponse.self, from: data)
            guard let choice = response.choices.first, choice.message.role == "assistant",
                  !choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChatClientError.invalidResponse
            }
            return ChatResponse(content: choice.message.content, finishReason: choice.finishReason,
                                model: response.model, usage: response.usage)
        } catch { throw ChatClientError.invalidResponse }
    }

    private func checkCancellation() throws {
        do { try Task.checkCancellation() }
        catch { throw ChatClientError.cancelled }
    }

    private func send(url: URL, credential: String?, body: Data? = nil) async throws -> Data {
        try checkCancellation()
        if let credential, credential.contains("\r") || credential.contains("\n") {
            throw ChatClientError.invalidParameters
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let credential, !credential.isEmpty {
            request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw ChatClientError.cancelled
            }
            throw ChatClientError.transport(code: (error as? URLError)?.code.rawValue ?? URLError.unknown.rawValue)
        }
        try checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ChatClientError.invalidResponse }
        if (300..<400).contains(response.statusCode) { throw ChatClientError.redirectRejected }
        guard (200..<300).contains(response.statusCode) else { throw ChatClientError.httpStatus(response.statusCode) }
        return data
    }
}

private struct OpenAIModels: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}
private struct OllamaModels: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}
private struct GenerationRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream = false
    let maxTokens: Int?
    let temperature: Double?
    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
    }
}
private struct GenerationResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let role: String; let content: String }
        let message: Message
        let finishReason: String?
        enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
    }
    let choices: [Choice]
    let model: String?
    let usage: ChatUsage?
}
