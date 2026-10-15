import Foundation
import Observation

/// Owns preparation until cancellation has drained. The UI never supplies model paths.
@MainActor @Observable public final class BuiltinModelPreparation {
    public private(set) var isBusy = false
    public private(set) var configuration: TranscriptionConfiguration?
    public private(set) var status = "内置模型尚未准备"
    public private(set) var errorMessage: String?
    public private(set) var progress: Double?
    @ObservationIgnored private let store: ManagedAssetStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var lastRank = -1
    @ObservationIgnored private var cancelled = false
    public init(store: ManagedAssetStore) { self.store = store }
    @discardableResult public func start() -> Bool {
        guard !isBusy else { return false }
        let id = UUID(); generation = id; isBusy = true; lastRank = -1; cancelled = false
        errorMessage = nil; configuration = nil; progress = nil; status = "正在准备内置模型…"
        task = Task { [weak self, store] in
            do {
                try await store.prepare { [weak self] value in await self?.receive(value, id: id) }
                try Task.checkCancellation()
                let configuration = try await store.defaultTranscriptionConfiguration()
                try Task.checkCancellation()
                self?.finish(id: id, configuration: configuration, error: nil)
            } catch { self?.finish(id: id, configuration: nil, error: error) }
        }
        return true
    }
    private func receive(_ value: ManagedAssetProgress, id: UUID) {
        guard generation == id, !cancelled else { return }
        // Download-delegate updates are asynchronous; discard late updates from an older phase.
        let assets = BuiltinAssetCatalog.assets
        let index = assets.firstIndex { $0.name == value.assetName } ?? 0
        let stages: [ManagedAssetProgress.Stage] = [.checking, .copying, .downloading, .extracting, .verifying, .installed]
        // Verification before extraction and verification after extraction are both valid.
        let phase = value.stage == .verifying ? 3 : (stages.firstIndex(of: value.stage) ?? 0)
        let rank = index * 10 + phase
        guard rank >= lastRank else { return }
        lastRank = rank
        status = "\(value.stage.rawValue)：\(value.assetName)"
        progress = value.totalBytes > 0 ? min(1, Double(value.completedBytes) / Double(value.totalBytes)) : nil
    }
    private func finish(id: UUID, configuration: TranscriptionConfiguration?, error: Error?) {
        guard generation == id else { isBusy = false; task = nil; return }
        generation = nil; self.configuration = configuration; isBusy = false; task = nil; progress = nil
        if let error { errorMessage = ManagedAssetStore.message(for: error); status = error is CancellationError ? "模型准备已取消" : "模型准备失败" }
        else { status = "内置转写与向量模型已准备" }
    }
    public func cancel() { guard isBusy else { return }; cancelled = true; status = "正在取消模型准备…"; task?.cancel() }
    public func waitUntilIdle() async { await task?.value }
    public func shutdown() async { cancel(); await waitUntilIdle() }
}
