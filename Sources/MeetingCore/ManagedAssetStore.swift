import Foundation
import CryptoKit
import CManagedArchive

public struct ManagedAsset: Codable, Sendable {
    public struct File: Codable, Sendable {
        public let path: String
        public let size: Int64
        public let sha256: String
    }
    public let id: String
    public let name: String
    public let url: URL
    public let size: Int64
    public let sha256: String
    /// nil is a direct file; empty string is a tar archive with files at its root.
    public let archiveRoot: String?
    public let files: [File]
    public var version: String { sha256 }
}

public enum BuiltinAssetCatalog {
    /// This resource ships in MeetingCore, independently of any bundle-provided seed.
    /// Bundle manifests and user-selected folders cannot override these trusted hashes.
    public static let assets: [ManagedAsset] = {
        let packagedBundle = (Bundle.main.resourceURL?.appendingPathComponent("MeetingMac_MeetingCore.bundle"))
            .flatMap { Bundle(url: $0) }
        let catalogBundle = packagedBundle ?? Bundle.module
        guard let url = catalogBundle.url(forResource: "builtin-assets", withExtension: "json"),
              let data = try? Data(contentsOf: url), let assets = try? JSONDecoder().decode([ManagedAsset].self, from: data) else {
            preconditionFailure("Missing immutable built-in asset catalog")
        }
        return assets
    }()
}
public enum ManagedAssetError: Error, Equatable, Sendable {
    case busy, unknownAsset(String), invalidManifest, invalidFile(String), integrity(String), archive(String), http(Int), responseTooLarge, insufficientDisk
}
public struct ManagedAssetProgress: Sendable {
    public enum Stage: String, Sendable { case checking = "检查", copying = "准备内置资源", downloading = "下载", verifying = "校验", extracting = "展开", installed = "已安装" }
    public let assetName: String
    public let stage: Stage
    public let completedBytes: Int64
    public let totalBytes: Int64
    public init(assetName: String, stage: Stage, completedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        self.assetName = assetName; self.stage = stage; self.completedBytes = completedBytes; self.totalBytes = totalBytes
    }
}

/// One admission gate for all default assets; each immutable version activates via rename.
/// No valid version is removed when another version fails, is cancelled, or is retried.
public actor ManagedAssetStore {
    public let root: URL
    private let seedRoot: URL?
    private let assets: [ManagedAsset]
    public private(set) var isBusy = false
    public init(root: URL = ManagedAssetStore.defaultRoot, seedRoot: URL? = nil, assets: [ManagedAsset] = BuiltinAssetCatalog.assets) {
        self.root = root.resolvingSymlinksInPath(); self.seedRoot = seedRoot?.resolvingSymlinksInPath(); self.assets = assets
    }
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingMac/ManagedAssets", isDirectory: true)
    }
    public func resolved(_ id: String) throws -> URL? {
        guard let asset = assets.first(where: { $0.id == id }) else { throw ManagedAssetError.unknownAsset(id) }
        try AssetInstaller.validate(asset)
        let url = root.appendingPathComponent(asset.id).appendingPathComponent(asset.version)
        return (try? AssetInstaller.verifyPayload(asset, at: url)) != nil ? url : nil
    }
    public func prepare(progress: @escaping @Sendable (ManagedAssetProgress) async -> Void = { _ in }) async throws {
        guard !isBusy else { throw ManagedAssetError.busy }
        isBusy = true
        defer { isBusy = false }
        let root = root, seedRoot = seedRoot, assets = assets
        // Heavy hashing, copying and extraction never run on an observable UI actor.
        let work = Task.detached {
            for asset in assets { try await AssetInstaller.install(asset, root: root, seedRoot: seedRoot, progress: progress) }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    public func defaultTranscriptionConfiguration() throws -> TranscriptionConfiguration {
        guard let model = try resolved("sensevoice-int8"), let runtime = try resolved("sherpa-onnx1.13.7") else {
            throw ManagedAssetError.invalidFile("默认语音模型尚未完成准备，请重试模型准备。")
        }
        var config = TranscriptionConfiguration()
        config.senseVoiceModel = model.path
        config.senseVoiceRuntime = runtime.appendingPathComponent("lib/libsherpa-onnx-c-api.dylib").path
        return config
    }
    // Resolve provenance from the same immutable/injected catalog that verified the payload.
    func embeddingDefinitions() throws -> (String, String) {
        guard let model = assets.first(where: { $0.id == "embeddinggemma300m" }),
              let runtime = assets.first(where: { $0.id == "llama-server-ollama0.40.4" }),
              let modelFile = model.files.first(where: { $0.path == "model.gguf" }),
              let runtimeFile = runtime.files.first(where: { $0.path == "llama-server" }) else { throw ManagedEmbeddingError.assetsUnavailable }
        return (modelFile.sha256, "llama-server-ollama0.40.4:" + runtimeFile.sha256)
    }
    public static func message(for error: Error) -> String {
        if error is CancellationError { return "已取消模型准备，可重试；已安装的有效版本保留。" }
        switch error as? ManagedAssetError {
        case .busy: return "已有模型准备任务正在运行。"
        case .integrity(let file): return "资源校验失败：\(file)。请重试准备模型。"
        case .invalidFile(let file): return "资源缺失或不是普通文件：\(file)。请重试准备模型。"
        case .insufficientDisk: return "可用磁盘空间不足，请清理后重试。"
        case .http(let code): return "模型下载失败（HTTP \(code)），请检查网络后重试。"
        case .responseTooLarge: return "模型下载大小异常，已停止。请重试。"
        case .archive: return "模型压缩包内容不符合固定清单，已停止安装。请重试。"
        default: return "模型准备失败：\(error.localizedDescription)。请检查网络和磁盘后重试。"
        }
    }
}

private enum AssetInstaller {
    static var fm: FileManager { FileManager.default }
    static func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func validate(_ asset: ManagedAsset) throws {
        let hashes = [asset.sha256] + asset.files.map(\.sha256)
        guard safe(asset.id), !asset.id.contains("/"), asset.size > 0, asset.size < 2_000_000_000,
              !asset.files.isEmpty, asset.files.count < 100,
              Set(asset.files.map(\.path)).count == asset.files.count,
              asset.files.allSatisfy({ safe($0.path) && $0.size > 0 && $0.size < 2_000_000_000 }),
              hashes.allSatisfy({ $0.count == 64 && $0.allSatisfy({ $0.isHexDigit }) }),
              asset.archiveRoot == nil || asset.archiveRoot == "" || safe(asset.archiveRoot!),
              asset.archiveRoot != nil || (asset.files.count == 1 && asset.files[0].size == asset.size && asset.files[0].sha256 == asset.sha256),
              asset.url.scheme == "https" || (asset.url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(asset.url.host ?? "")) else { throw ManagedAssetError.invalidManifest }
    }
    static func regular(_ url: URL, size: Int64) throws {
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true, Int64(v.fileSize ?? -1) == size else { throw ManagedAssetError.invalidFile(url.lastPathComponent) }
    }
    static func digest(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hash = SHA256()
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation(); hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func verifyPayload(_ asset: ManagedAsset, at root: URL) throws {
        let base = root.standardizedFileURL.path
        guard root.resolvingSymlinksInPath().path == base else { throw ManagedAssetError.invalidFile(asset.id) }
        for file in asset.files {
            let path = root.appendingPathComponent(file.path)
            guard path.resolvingSymlinksInPath().path == path.standardizedFileURL.path else { throw ManagedAssetError.invalidFile(file.path) }
            try regular(path, size: file.size)
            guard try digest(path) == file.sha256 else { throw ManagedAssetError.integrity(file.path) }
        }
    }
    static func copy(_ source: URL, to destination: URL, expected: ManagedAsset.File) throws {
        try regular(source, size: expected.size)
        guard source.resolvingSymlinksInPath().path == source.standardizedFileURL.path else { throw ManagedAssetError.invalidFile(expected.path) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        var hash = SHA256(), total: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation(); total += Int64(chunk.count)
            guard total <= expected.size else { throw ManagedAssetError.integrity(expected.path) }
            hash.update(data: chunk); try output.write(contentsOf: chunk)
        }
        guard total == expected.size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected.sha256 else { throw ManagedAssetError.integrity(expected.path) }
    }
    static func install(_ asset: ManagedAsset, root: URL, seedRoot: URL?, progress: @escaping @Sendable (ManagedAssetProgress) async -> Void) async throws {
        try validate(asset); try Task.checkCancellation()
        await progress(.init(assetName: asset.name, stage: .checking))
        let destination = root.appendingPathComponent(asset.id).appendingPathComponent(asset.version)
        if (try? verifyPayload(asset, at: destination)) != nil { await progress(.init(assetName: asset.name, stage: .installed)); return }
        try Task.checkCancellation()
        let stagingRoot = root.appendingPathComponent(".staging", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Only this operation's UUID directory is removed, never another job's files.
        let stage = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let needed = asset.size + asset.files.reduce(Int64(0)) { $0 + $1.size } + 32_000_000
        let available = try stage.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let available, available < needed { throw ManagedAssetError.insufficientDisk }
        let payload = stage.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: false)
        var copiedSeed = false
        if let seedRoot, fm.fileExists(atPath: seedRoot.appendingPathComponent(asset.id).path) {
            await progress(.init(assetName: asset.name, stage: .copying))
            do {
                for file in asset.files { try copy(seedRoot.appendingPathComponent(asset.id).appendingPathComponent(file.path), to: payload.appendingPathComponent(file.path), expected: file) }
                copiedSeed = true
            } catch {
                // An incomplete/corrupt seed is not a permanent retry loop. Only a fully
                // verified download may replace it; cancellation still stops immediately.
                try Task.checkCancellation()
                try fm.removeItem(at: payload)
                try fm.createDirectory(at: payload, withIntermediateDirectories: false)
            }
        }
        if !copiedSeed {
            let download = stage.appendingPathComponent("download")
            await progress(.init(assetName: asset.name, stage: .downloading, totalBytes: asset.size))
            let transfer = AssetDownload(url: asset.url, destination: download, limit: asset.size) { bytes in
                // Delegate progress is throttled and carries only byte counts, never URLs or credentials.
                Task { await progress(.init(assetName: asset.name, stage: .downloading, completedBytes: bytes, totalBytes: asset.size)) }
            }
            try await transfer.run()
            await progress(.init(assetName: asset.name, stage: .verifying))
            try regular(download, size: asset.size)
            guard try digest(download) == asset.sha256 else { throw ManagedAssetError.integrity(asset.id) }
            try Task.checkCancellation()
            if let archiveRoot = asset.archiveRoot {
                await progress(.init(assetName: asset.name, stage: .extracting))
                try extract(download, payload: payload, asset: asset, archiveRoot: archiveRoot)
            } else { try fm.moveItem(at: download, to: payload.appendingPathComponent(asset.files[0].path)) }
        }
        await progress(.init(assetName: asset.name, stage: .verifying))
        try verifyPayload(asset, at: payload)
        for file in asset.files where file.path == "llama-server" { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payload.appendingPathComponent(file.path).path) }
        try Task.checkCancellation()
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Existing corrupt version is moved aside only after the new payload fully validates.
        let backup = stage.appendingPathComponent("previous")
        let exists = fm.fileExists(atPath: destination.path)
        if exists { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: payload, to: destination) }
        catch { if exists { try? fm.moveItem(at: backup, to: destination) }; throw error }
        await progress(.init(assetName: asset.name, stage: .installed))
    }
    static func extract(_ archive: URL, payload: URL, asset: ManagedAsset, archiveRoot: String) throws {
        for file in asset.files { try fm.createDirectory(at: payload.appendingPathComponent(file.path).deletingLastPathComponent(), withIntermediateDirectories: true) }
        let members = asset.files.map { strdup((archiveRoot.isEmpty ? "" : archiveRoot + "/") + $0.path) }
        let outputs = asset.files.map { strdup($0.path) }
        defer { members.forEach { free($0) }; outputs.forEach { free($0) } }
        var inputs = members.map { UnsafePointer<CChar>($0) }, targets = outputs.map { UnsafePointer<CChar>($0) }
        var sizes = asset.files.map(\.size), message = [CChar](repeating: 0, count: 2048)
        let result = mm_extract(archive.path, payload.path, &inputs, &targets, &sizes, Int32(asset.files.count), { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil, &message, Int32(message.count))
        try Task.checkCancellation()
        guard result == 0 else { throw ManagedAssetError.archive(String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
    }
}

/// URLSession's download delegate streams to its private temporary file. No model-sized
/// Data object exists; oversized or wrong-status responses are cancelled before activation.
private final class AssetDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL, destination: URL, limit: Int64
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var failure: Error?
    private var cancelled = false
    private var lastProgress = Date.distantPast
    init(url: URL, destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.url = url; self.destination = destination; self.limit = limit; self.progress = progress
    }
    func run() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
                config.httpShouldSetCookies = false; config.connectionProxyDictionary = [:]
                config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let task = session.downloadTask(with: request); self.task = task
                if cancelled { task.cancel() }; task.resume()
            }
        } onCancel: { self.lock.lock(); self.cancelled = true; self.task?.cancel(); self.lock.unlock() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Public artifact redirects may change CDN host, but never downgrade HTTPS.
        guard let target = request.url, target.scheme == "https" || (url.scheme == "http" && target.host == url.host && target.port == url.port) else { completionHandler(nil); return }
        var clean = URLRequest(url: target); clean.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        completionHandler(clean)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { failure = ManagedAssetError.responseTooLarge; downloadTask.cancel(); return }
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 { failure = ManagedAssetError.http(response.statusCode); downloadTask.cancel(); return }
        if Date().timeIntervalSince(lastProgress) >= 0.15 { lastProgress = Date(); progress(totalBytesWritten) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else { failure = ManagedAssetError.http((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0); return }
        do {
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard Int64(size) == limit else { throw ManagedAssetError.integrity("下载大小") }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { failure = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = continuation; self.continuation = nil
        let outcome: Error? = cancelled ? CancellationError() : (failure ?? error)
        self.task = nil; self.session = nil; lock.unlock()
        session.finishTasksAndInvalidate()
        if let outcome { continuation?.resume(throwing: outcome) } else { continuation?.resume() }
    }
}
