import XCTest
import CryptoKit
import Darwin
@testable import MeetingCore

final class ManagedAssetTests: XCTestCase, @unchecked Sendable {
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func fixture(_ bytes: Data = Data("verified model".utf8), id: String = "fixture") throws -> (URL, URL, ManagedAsset) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed.appendingPathComponent(id), withIntermediateDirectories: true)
        try bytes.write(to: seed.appendingPathComponent(id + "/model.bin"))
        let file = ManagedAsset.File(path: "model.bin", size: Int64(bytes.count), sha256: hash(bytes))
        let asset = ManagedAsset(id: id, name: "测试模型", url: URL(string: "http://127.0.0.1:1/model")!, size: Int64(bytes.count), sha256: hash(bytes), archiveRoot: nil, files: [file])
        return (root, seed, asset)
    }
    func testCatalogPinsOnlyExplicitDefaultRolesAndHashes() throws {
        let assets = BuiltinAssetCatalog.assets
        XCTAssertEqual(Set(assets.map(\.id)), ["sensevoice-int8", "embeddinggemma300m", "sherpa-onnx1.13.7", "llama-server-ollama0.40.4"])
        XCTAssertTrue(assets.allSatisfy { $0.url.scheme == "https" && $0.sha256.count == 64 && $0.size > 0 && !$0.files.isEmpty })
        XCTAssertEqual(TranscriptionConfiguration().engine, .senseVoice)
    }
    func testVerifiedSeedInstallsWithoutNetworkAndResolvesOnlyCompleteFiles() async throws {
        let (root, seed, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ManagedAssetStore(root: root.appendingPathComponent("managed"), seedRoot: seed, assets: [asset])
        let missing = try await store.resolved(asset.id); XCTAssertNil(missing)
        try await store.prepare()
        let resolvedDirectory = try await store.resolved(asset.id)
        let directory = try XCTUnwrap(resolvedDirectory)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("model.bin")), Data("verified model".utf8))
        try Data("bad".utf8).write(to: directory.appendingPathComponent("model.bin"))
        let invalid = try await store.resolved(asset.id); XCTAssertNil(invalid)
    }
    func testWrongHashShortMissingAndSymlinkSeedsAreNeverActivated() async throws {
        for mode in ["hash", "short", "missing", "symlink"] {
            let (root, seed, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let file = seed.appendingPathComponent(asset.id + "/model.bin")
            if mode == "hash" { try Data("unverified xxx".utf8).write(to: file) }
            if mode == "short" { try Data("x".utf8).write(to: file) }
            if mode == "missing" || mode == "symlink" { try FileManager.default.removeItem(at: file) }
            if mode == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: "/etc/hosts")) }
            let store = ManagedAssetStore(root: root.appendingPathComponent("managed"), seedRoot: seed, assets: [asset])
            do { try await store.prepare(); XCTFail("Invalid seed cannot install") } catch {}
            let result = try await store.resolved(asset.id); XCTAssertNil(result)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("managed/.staging").path), [])
        }
    }
    func testIncompleteOrCorruptBundledSeedRecoversUsingVerifiedHTTPDownload() async throws {
        let server = try AssetHTTPServer(); defer { server.stop() }
        for mode in ["missing", "corrupt", "symlink"] {
            let (root, seed, fixture) = try fixture(Data(repeating: 7, count: 65536))
            defer { try? FileManager.default.removeItem(at: root) }
            let source = seed.appendingPathComponent(fixture.id + "/model.bin")
            try FileManager.default.removeItem(at: source)
            if mode == "corrupt" { try Data(repeating: 8, count: 65536).write(to: source) }
            if mode == "symlink" { try FileManager.default.createSymbolicLink(at: source, withDestinationURL: URL(fileURLWithPath: "/etc/hosts")) }
            let asset = ManagedAsset(id: fixture.id, name: fixture.name, url: server.url("model"), size: fixture.size, sha256: fixture.sha256, archiveRoot: nil, files: fixture.files)
            let store = ManagedAssetStore(root: root.appendingPathComponent("managed"), seedRoot: seed, assets: [asset])
            try await store.prepare()
            let resolved = try await store.resolved(asset.id)
            XCTAssertNotNil(resolved, "Invalid bundled seed must recover from fixed verified download")
        }
    }
    func testFailureAndCancellationPreservePreviouslyVerifiedVersion() async throws {
        let (root, seed, old) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed")
        let first = ManagedAssetStore(root: managed, seedRoot: seed, assets: [old])
        try await first.prepare()
        let newer = ManagedAsset(id: old.id, name: old.name, url: old.url, size: old.size + 1, sha256: String(repeating: "a", count: 64), archiveRoot: nil, files: old.files)
        let failed = ManagedAssetStore(root: managed, seedRoot: nil, assets: [newer])
        do { try await failed.prepare(); XCTFail() } catch {}
        let task = Task { try await failed.prepare() }; task.cancel()
        do { try await task.value; XCTFail() } catch {}
        let preserved = try await first.resolved(old.id); XCTAssertNotNil(preserved)
    }
    func testSingleJobAndCancellationDrain() async throws {
        let server = try AssetHTTPServer(); defer { server.stop() }
        let (root, _, fixture) = try fixture(Data(repeating: 7, count: 65536)); defer { try? FileManager.default.removeItem(at: root) }
        let asset = ManagedAsset(id: fixture.id, name: fixture.name, url: server.url("slow"), size: fixture.size, sha256: fixture.sha256, archiveRoot: nil, files: fixture.files)
        let store = ManagedAssetStore(root: root.appendingPathComponent("managed"), assets: [asset])
        let started = DownloadStarted()
        let first = Task { try await store.prepare { value in
            if value.stage == .downloading && value.completedBytes > 0 { await started.mark() }
        } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await started.value), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let received = await started.value; XCTAssertTrue(received, "Cancel an active HTTP transfer, not only a queued task")
        do { try await store.prepare(); XCTFail("Second install must be rejected") } catch { XCTAssertEqual(error as? ManagedAssetError, .busy) }
        first.cancel()
        do { try await first.value; XCTFail() } catch {}
        let busy = await store.isBusy; XCTAssertFalse(busy)
        let resolved = try await store.resolved(asset.id); XCTAssertNil(resolved)
    }
    func testActualHTTPDownloadRetryAndResponseBounds() async throws {
        let server = try AssetHTTPServer(); defer { server.stop() }
        for route in ["model", "short", "wrong", "large", "status"] {
            let (root, _, fixture) = try fixture(Data(repeating: 7, count: 65536)); defer { try? FileManager.default.removeItem(at: root) }
            let makeAsset: (String) -> ManagedAsset = { route in .init(id: fixture.id, name: fixture.name, url: server.url(route), size: fixture.size, sha256: fixture.sha256, archiveRoot: nil, files: fixture.files) }
            let managed = root.appendingPathComponent("managed")
            let store = ManagedAssetStore(root: managed, assets: [makeAsset(route)])
            do { try await store.prepare(); XCTAssertEqual(route, "model") } catch { XCTAssertNotEqual(route, "model", "\(error)") }
            let result = try await store.resolved(fixture.id)
            XCTAssertEqual(result != nil, route == "model")
            // Retry starts from a new private stage and never reuses a truncated response.
            let retry = ManagedAssetStore(root: managed, assets: [makeAsset("model")]); try await retry.prepare()
            let recovered = try await retry.resolved(fixture.id); XCTAssertNotNil(recovered)
        }
    }
    func testArchiveWhitelistAndEscapeReject() async throws {
        let server = try AssetHTTPServer(); defer { server.stop() }
        for route in ["archive", "escape", "symlink"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
            let archive = try Data(contentsOf: server.url(route))
            let payload = Data("verified archive".utf8)
            let asset = ManagedAsset(id: "archive", name: "archive", url: server.url(route), size: Int64(archive.count), sha256: hash(archive), archiveRoot: "fixed", files: [.init(path: "model.bin", size: Int64(payload.count), sha256: hash(payload))])
            let store = ManagedAssetStore(root: root, assets: [asset])
            do { try await store.prepare(); XCTAssertEqual(route, "archive") } catch { XCTAssertNotEqual(route, "archive", "\(error)") }
            let installed = try await store.resolved(asset.id); XCTAssertEqual(installed != nil, route == "archive")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped").path))
        }
    }
    func testDefaultConfigurationCannotResolvePartialInstallation() async throws {
        let (root, seed, fixture) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = ManagedAsset(id: "sensevoice-int8", name: "asr", url: fixture.url, size: fixture.size, sha256: fixture.sha256, archiveRoot: nil, files: fixture.files)
        let runtime = ManagedAsset(id: "sherpa-onnx1.13.7", name: "runtime", url: fixture.url, size: fixture.size, sha256: fixture.sha256, archiveRoot: nil, files: fixture.files)
        for asset in [model, runtime] {
            try FileManager.default.createDirectory(at: seed.appendingPathComponent(asset.id), withIntermediateDirectories: true)
            try Data("verified model".utf8).write(to: seed.appendingPathComponent(asset.id + "/model.bin"))
        }
        let store = ManagedAssetStore(root: root.appendingPathComponent("managed"), seedRoot: seed, assets: [model, runtime])
        do { _ = try await store.defaultTranscriptionConfiguration(); XCTFail("Missing assets must not become ready") } catch {}
        try await store.prepare()
        let configuration = try await store.defaultTranscriptionConfiguration()
        XCTAssertEqual(configuration.engine, .senseVoice)
        XCTAssertTrue(configuration.senseVoiceModel.hasPrefix(root.resolvingSymlinksInPath().path))
        XCTAssertTrue(configuration.senseVoiceRuntime.hasSuffix("lib/libsherpa-onnx-c-api.dylib"))
    }
    func testManifestCannotWriteOutsideManagedDirectory() async throws {
        let (root, _, fixture) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for path in ["../escaped", "/absolute", "a/../escaped", "a//b"] {
            let asset = ManagedAsset(id: "fixture", name: "invalid", url: fixture.url, size: fixture.size, sha256: fixture.sha256, archiveRoot: nil, files: [.init(path: path, size: fixture.size, sha256: fixture.sha256)])
            let store = ManagedAssetStore(root: root.appendingPathComponent("managed"), assets: [asset])
            do { try await store.prepare(); XCTFail() } catch { XCTAssertEqual(error as? ManagedAssetError, .invalidManifest) }
        }
    }
    @MainActor func testPreparationFailureReportsErrorAndAllowsRetryAfterDrain() async throws {
        let (root, seed, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let preparation = BuiltinModelPreparation(store: ManagedAssetStore(root: root.appendingPathComponent("managed"), seedRoot: seed, assets: [asset]))
        XCTAssertTrue(preparation.start())
        XCTAssertFalse(preparation.start())
        await preparation.waitUntilIdle()
        XCTAssertFalse(preparation.isBusy)
        XCTAssertNil(preparation.configuration, "A generic asset does not satisfy default ASR/runtime readiness")
        XCTAssertNotNil(preparation.errorMessage)
        XCTAssertTrue(preparation.start())
        await preparation.shutdown()
        XCTAssertFalse(preparation.isBusy)
        XCTAssertNil(preparation.configuration)
    }

}

private actor DownloadStarted {
    var value = false
    func mark() { value = true }
}

private final class AssetHTTPServer {
    let process = Process()
    let urlBase: URL
    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/asset_server.py")
        process.arguments = [script.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        try? output.fileHandleForWriting.close()
        defer { try? output.fileHandleForReading.close() }
        do {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 5000) > 0 else { throw CocoaError(.fileReadUnknown) }
            let line = output.fileHandleForReading.availableData
            guard line.count < 128, let port = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else { throw CocoaError(.fileReadCorruptFile) }
            urlBase = URL(string: "http://127.0.0.1:\(port)/")!
        } catch { Self.stop(process); throw error }
    }
    func url(_ route: String) -> URL { urlBase.appendingPathComponent(route) }
    private static func stop(_ process: Process) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for _ in 0..<100 where process.isRunning { usleep(10_000) }
        XCTAssertFalse(process.isRunning, "Owned fixture must be reaped")
    }
    func stop() { Self.stop(process) }
}
