import XCTest
import PDFKit
import CoreText
import AppKit
import CSQLite
import Darwin
@testable import MeetingCore

final class SourceIndexTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ text: String, at root: URL, name: String = "资料.md") throws -> URL {
        let url = root.appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
    }
    private func engine(_ gate: IndexTestEmbedder = IndexTestEmbedder()) -> SourceEmbeddingProvider {
        SourceEmbeddingProvider(space: .managed, embed: { try await gate.embed($0) }, shutdown: { await gate.stop() })
    }
    func testSnapshotDuplicateRevisionAndReopen() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try write("中文预算👨‍👩‍👧‍👦 e\u{301}\n" + String(repeating: "完整原文", count: 200), at: dir)
        let db = dir.appendingPathComponent("index.sqlite")
        let service = try SourceIndex(databaseURL: db, embedding: engine())
        let first = try await service.ingest(file: file, accountScope: "local")
        let duplicate = try await service.ingest(file: file, accountScope: "local")
        XCTAssertEqual(first.activeRevisionID, duplicate.activeRevisionID)
        let original = try await service.detail(sourceID: first.id)
        _ = try write("新预算", at: dir)
        let before = try await service.detail(sourceID: first.id)
        XCTAssertEqual(before?.text, original?.text)
        let second = try await service.ingest(file: file, accountScope: "local")
        XCTAssertNotEqual(first.activeRevisionID, second.activeRevisionID)
        await service.shutdown()
        let reopened = try SourceIndex(databaseURL: db, embedding: engine())
        let detail = try await reopened.detail(sourceID: first.id)
        XCTAssertEqual(detail?.text, "新预算")
        let hits = try await reopened.search("预算", sourceIDs: [first.id], accountScopes: ["local"])
        XCTAssertEqual(hits.map(\.revisionID), [second.activeRevisionID!])
        XCTAssertEqual(hits.first?.text, "新预算")
        await reopened.shutdown()
    }
    func testFailuresNeverReplaceActiveRevision() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = IndexTestEmbedder(), file = try write("旧有效内容", at: dir)
        let index = try SourceIndex(databaseURL: dir.appendingPathComponent("db"), embedding: engine(gate))
        let old = try await index.ingest(file: file, accountScope: "a")
        for mode in ["failure", "dimension", "space", "nan", "norm", "context"] {
            _ = try write(String(repeating: "新资料", count: 300), at: dir)
            await gate.configure(mode, failAt: 2)
            do { _ = try await index.ingest(file: file, accountScope: "a"); XCTFail("Expected \(mode)") } catch {}
            let detail = try await index.detail(sourceID: old.id)
            XCTAssertEqual(detail?.source.activeRevisionID, old.activeRevisionID)
            XCTAssertEqual(detail?.text, "旧有效内容")
            XCTAssertEqual(detail?.source.status, "failed")
        }
        await gate.configure("normal")
        let current = try await index.ingest(file: file, accountScope: "a")
        XCTAssertNotEqual(current.activeRevisionID, old.activeRevisionID)
        await index.shutdown()
        let stops = await gate.stopCount(); XCTAssertEqual(stops, 1)
    }
    private func sql(_ sql: String, at url: URL) throws -> [[String]] {
        var db: OpaquePointer?; guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SourceIndexError.database }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw SourceIndexError.database }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw SourceIndexError.database }
            result.append((0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_text(statement, $0)) })
        }
    }
    func testCanonicalSpaceIdentityAndTransactionalActivationRollback() async throws {
        let key = try SourceEmbeddingSpace.managed.key
        for _ in 0..<100 { XCTAssertEqual(try SourceEmbeddingSpace.managed.key, key) }
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("db"), file = try write("first", at: dir)
        let index = try SourceIndex(databaseURL: db, embedding: engine())
        let first = try await index.ingest(file: file, accountScope: "a")
        _ = try sql("CREATE TRIGGER activation_failure BEFORE UPDATE OF active ON sources BEGIN SELECT RAISE(ABORT, 'test disk/write failure'); END", at: db)
        _ = try write("second", at: dir)
        do { _ = try await index.ingest(file: file, accountScope: "a"); XCTFail("must roll back") } catch SourceIndexError.database {}
        let detail = try await index.detail(sourceID: first.id)
        XCTAssertEqual(detail?.text, "first")
        XCTAssertEqual(try sql("SELECT count(*) FROM revisions", at: db), [["1"]])
        XCTAssertEqual(try sql("SELECT count(*) FROM chunks", at: db), [["1"]])
        _ = try sql("DROP TRIGGER activation_failure", at: db)
        try await index.delete(sourceID: first.id)
        XCTAssertEqual(try sql("SELECT count(*) FROM revisions", at: db), [["0"]])
        XCTAssertEqual(try sql("SELECT count(*) FROM chunks", at: db), [["0"]])
        XCTAssertEqual(try sql("PRAGMA foreign_key_check", at: db), [])
        await index.shutdown()
    }
    func testLongWhitespaceSpansPreserveSnapshotWithoutEmptyEmbeddingRequests() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let text = "first paragraph" + String(repeating: " \n", count: 800) + "last paragraph"
        let index = try SourceIndex(databaseURL: dir.appendingPathComponent("db"), embedding: engine())
        let source = try await index.ingest(file: write(text, at: dir), accountScope: "a")
        let detail = try await index.detail(sourceID: source.id)
        XCTAssertEqual(detail?.text, text)
        XCTAssertTrue(detail!.chunks.first!.text.contains("first paragraph"))
        XCTAssertTrue(detail!.chunks.last!.text.contains("last paragraph"))
        for chunk in detail!.chunks {
            XCTAssertFalse(chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: chunk.anchor.snapshotUTF16Offset, length: chunk.anchor.utf16Length)), chunk.text)
        }
        await index.shutdown()
    }
    func testCosineCompensatesForPermittedFloatNormalizationRounding() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = IndexTestEmbedder(); await gate.configure("nearUnit")
        let index = try SourceIndex(databaseURL: dir.appendingPathComponent("db"), embedding: engine(gate))
        let source = try await index.ingest(file: write("预算", at: dir), accountScope: "a")
        let hits = try await index.search("预算", sourceIDs: [source.id], accountScopes: ["a"])
        XCTAssertEqual(hits[0].score, 1, accuracy: 0.000001)
        await index.shutdown()
    }
    func testMalformedPersistedSpaceAndVectorsFailWithoutCrashing() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("db"), file = try write("资料", at: dir)
        let index = try SourceIndex(databaseURL: db, embedding: engine())
        let source = try await index.ingest(file: file, accountScope: "a")
        _ = try sql("UPDATE chunks SET vector='[0]'", at: db)
        do { _ = try await index.search("资料", sourceIDs: [source.id], accountScopes: ["a"]); XCTFail("bad vector") } catch SourceIndexError.invalidVector {}
        _ = try sql("UPDATE revisions SET space='malformed'", at: db)
        do { _ = try await index.detail(sourceID: source.id); XCTFail("bad space") } catch SourceIndexError.invalidEmbeddingSpace {}
        await index.shutdown()
    }
    func testNonRegularFilesAndInitialFailureNeverClaimIndexed() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("pipe.txt")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let gate = IndexTestEmbedder(), db = dir.appendingPathComponent("db")
        let index = try SourceIndex(databaseURL: db, embedding: engine(gate))
        do { _ = try await index.ingest(file: fifo, accountScope: "a"); XCTFail("fifo") } catch SourceIndexError.nonRegularFile {}
        await gate.configure("failure")
        let file = try write("failed first import", at: dir)
        do { _ = try await index.ingest(file: file, accountScope: "a"); XCTFail("failure") } catch ManagedEmbeddingError.transport {}
        let list = try await index.list(); XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].status, "failed"); XCTAssertNil(list[0].activeRevisionID)
        XCTAssertEqual(try sql("SELECT count(*) FROM revisions", at: db), [["0"]])
        await index.shutdown()
    }
    func testRankedTopKStableIDsAndSameBytesDifferentSources() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let index = try SourceIndex(databaseURL: dir.appendingPathComponent("db"), embedding: engine())
        let one = try await index.ingest(file: write("相关预算", at: dir, name: "one.txt"), accountScope: "a")
        let two = try await index.ingest(file: write("不相关天气", at: dir, name: "two.txt"), accountScope: "a")
        let three = try await index.ingest(file: write("相关预算", at: dir, name: "three.txt"), accountScope: "a")
        XCTAssertNotEqual(one.id, three.id)
        let scope: Set<String> = [one.id, two.id, three.id]
        let hits = try await index.search("相关预算", sourceIDs: scope, accountScopes: ["a"], limit: 3)
        XCTAssertEqual(hits.count, 3); XCTAssertEqual(hits.last?.sourceID, two.id)
        XCTAssertEqual(hits.first?.score, 1); XCTAssertEqual(hits.last?.score, 0)
        let again = try await index.search("相关预算", sourceIDs: scope, accountScopes: ["a"], limit: 1)
        XCTAssertEqual(again.first?.chunkID, hits.first?.chunkID)
        await index.shutdown()
    }
    func testNewCoordinatorGenerationCannotBeOverwrittenByLateJob() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("db"), file = try write("old pending input", at: dir)
        let gate = IndexTestEmbedder(); await gate.configure("wait")
        let old = try SourceIndex(databaseURL: db, embedding: engine(gate))
        let task = Task { try await old.ingest(file: file, accountScope: "a") }
        await gate.waitUntilBlocked()
        let current = try SourceIndex(databaseURL: db, embedding: engine())
        _ = try write("new coordinator input", at: dir)
        let source = try await current.ingest(file: file, accountScope: "a")
        await gate.release()
        do { _ = try await task.value; XCTFail("old generation") } catch SourceIndexError.superseded {}
        let detail = try await current.detail(sourceID: source.id)
        XCTAssertEqual(detail?.text, "new coordinator input")
        XCTAssertEqual(detail?.source.status, "indexed")
        await old.shutdown(); await current.shutdown()
    }
    func testCancelledIngestRetainsOldRevision() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = IndexTestEmbedder(), file = try write("旧版", at: dir)
        let index = try SourceIndex(databaseURL: dir.appendingPathComponent("db"), embedding: engine(gate))
        let old = try await index.ingest(file: file, accountScope: "a")
        _ = try write("更新版", at: dir)
        await gate.configure("wait")
        let task = Task { try await index.ingest(file: file, accountScope: "a") }
        await gate.waitUntilBlocked(); task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("cancelled") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let detail = try await index.detail(sourceID: old.id)
        XCTAssertEqual(detail?.source.activeRevisionID, old.activeRevisionID)
        await index.shutdown()
    }
    func testLateIngestAfterDeleteOrRevokeCannotActivate() async throws {
        for deletion in [true, false] {
            let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
            let gate = IndexTestEmbedder(), file = try write("旧版", at: dir)
            let index = try SourceIndex(databaseURL: dir.appendingPathComponent("db"), embedding: engine(gate))
            let old = try await index.ingest(file: file, accountScope: "a")
            _ = try write("新版", at: dir); await gate.configure("wait")
            let task = Task { try await index.ingest(file: file, accountScope: "a") }
            await gate.waitUntilBlocked()
            if deletion { try await index.delete(sourceID: old.id) } else { try await index.revoke(sourceID: old.id) }
            await gate.release()
            do { _ = try await task.value; XCTFail("late activation") } catch SourceIndexError.superseded {} catch { XCTFail("\(error)") }
            let hits = try await index.search("资料", sourceIDs: [old.id], accountScopes: ["a"])
            XCTAssertTrue(hits.isEmpty)
            if deletion { let detail = try await index.detail(sourceID: old.id); XCTAssertNil(detail) }
            await index.shutdown()
        }
    }
    func testSearchPermissionsRecheckedAfterEmbeddingAndScopeSpaceIsolation() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = IndexTestEmbedder(), file = try write("知识👋", at: dir)
        let db = dir.appendingPathComponent("db")
        let index = try SourceIndex(databaseURL: db, embedding: engine(gate))
        let first = try await index.ingest(file: file, accountScope: "a")
        let second = try await index.ingest(file: file, accountScope: "b")
        let wrongAccount = try await index.search("知识", sourceIDs: [first.id], accountScopes: ["b"])
        let noScope = try await index.search("知识", sourceIDs: [], accountScopes: ["a"])
        XCTAssertTrue(wrongAccount.isEmpty); XCTAssertTrue(noScope.isEmpty)
        let hits = try await index.search("知识", sourceIDs: [second.id], accountScopes: ["b"])
        XCTAssertEqual(hits.map(\.sourceID), [second.id])
        await gate.configure("wait")
        let task = Task { try await index.search("知识", sourceIDs: [first.id], accountScopes: ["a"]) }
        await gate.waitUntilBlocked(); try await index.revoke(sourceID: first.id); await gate.release()
        let late = try await task.value; XCTAssertTrue(late.isEmpty)
        await index.shutdown()
        let other = SourceEmbeddingSpace(model: "other", checkpointSHA256: "other", runtimeRevision: "other")
        let alternate = SourceEmbeddingProvider(space: other, embed: { inputs in
            inputs.map { input in
                var v = [Float](repeating: 0, count: 768); v[0] = 1
                return EmbeddingResult(input: input, vector: v, model: "other", checkpointSHA256: "other", runtimeRevision: "other", executionLocation: .onDevice)
            }
        }, shutdown: {})
        let reopened = try SourceIndex(databaseURL: db, embedding: alternate)
        let excluded = try await reopened.search("知识", sourceIDs: [second.id], accountScopes: ["b"])
        XCTAssertTrue(excluded.isEmpty)
        await reopened.shutdown()
    }
    func testExtractionUnicodeAnchorsPDFAndInputFailures() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let index = try SourceIndex(databaseURL: dir.appendingPathComponent("db"), embedding: engine())
        let text = String(repeating: "中👨‍👩‍👧‍👦e\u{301}", count: 100)
        let file = try write(text, at: dir)
        let source = try await index.ingest(file: file, accountScope: "a")
        let detail = try await index.detail(sourceID: source.id)
        XCTAssertEqual(detail?.chunks.map(\.text).joined(), text)
        for chunk in detail!.chunks {
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: chunk.anchor.snapshotUTF16Offset, length: chunk.anchor.utf16Length)), chunk.text)
        }
        for (bytes, name, expected) in [(Data(), "empty.txt", SourceIndexError.emptyText), (Data([0xff]), "bad.txt", .invalidUTF8), (Data("broken".utf8), "bad.pdf", .invalidPDF), (Data(repeating: 65, count: SourceIndex.maximumFileBytes + 1), "large.txt", .fileTooLarge), (Data(repeating: 65, count: SourceIndex.maximumTextBytes + 1), "text.txt", .textTooLarge)] {
            let url = dir.appendingPathComponent(name); try bytes.write(to: url)
            do { _ = try await index.ingest(file: url, accountScope: "a"); XCTFail(name) } catch let error as SourceIndexError { XCTAssertEqual(error, expected) }
        }
        let chunkLimit = try write(String(repeating: "a", count: SourceIndex.maximumChunks * 384 + 1), at: dir, name: "chunks.txt")
        do { _ = try await index.ingest(file: chunkLimit, accountScope: "a"); XCTFail("chunk budget") } catch SourceIndexError.tooManyChunks {}
        let tooManyPages = PDFDocument()
        for page in 0...SourceIndex.maximumPDFPages { tooManyPages.insert(PDFPage(), at: page) }
        let pagesURL = dir.appendingPathComponent("many.pdf"); XCTAssertTrue(tooManyPages.write(to: pagesURL))
        do { _ = try await index.ingest(file: pagesURL, accountScope: "a"); XCTFail("page budget") } catch SourceIndexError.tooManyPages {}
        let pdf = dir.appendingPathComponent("pages.pdf")
        let context = CGContext(pdf as CFURL, mediaBox: nil, nil)!
        for label in ["first page", "second page"] {
            context.beginPDFPage(nil); context.textPosition = CGPoint(x: 30, y: 700)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 16)]))
            CTLineDraw(line, context); context.endPDFPage()
        }
        context.closePDF()
        let pdfSource = try await index.ingest(file: pdf, accountScope: "a")
        let pdfDetail = try await index.detail(sourceID: pdfSource.id)
        XCTAssertEqual(pdfDetail?.chunks.map { $0.anchor.page }, [1, 2])
        XCTAssertTrue(pdfDetail!.text!.contains("second page"))
        for chunk in pdfDetail!.chunks {
            XCTAssertEqual((pdfDetail!.text! as NSString).substring(with: NSRange(location: chunk.anchor.snapshotUTF16Offset, length: chunk.anchor.utf16Length)), chunk.text)
        }
        let document = PDFDocument(); document.insert(PDFPage(), at: 0)
        let imagePDF = dir.appendingPathComponent("image.pdf"); XCTAssertTrue(document.write(to: imagePDF))
        do { _ = try await index.ingest(file: imagePDF, accountScope: "a"); XCTFail("no OCR") } catch SourceIndexError.emptyText {}
        await index.shutdown()
    }

}

private actor IndexTestEmbedder {
    private var mode = "normal", calls = 0, failAt = 1, stops = 0
    private var blocked: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func configure(_ mode: String, failAt: Int = 1) { self.mode = mode; self.failAt = failAt; calls = 0 }
    func waitUntilBlocked() async { if blocked != nil { return }; await withCheckedContinuation { observer = $0 } }
    func release() { mode = "normal"; blocked?.resume(); blocked = nil }
    func embed(_ inputs: [EmbeddingInput]) async throws -> [EmbeddingResult] {
        guard inputs.allSatisfy(\.valid) else { throw ManagedEmbeddingError.invalidInput }
        calls += 1
        if mode == "wait" { await withCheckedContinuation { blocked = $0; observer?.resume(); observer = nil } }
        if calls == failAt && mode == "failure" { throw ManagedEmbeddingError.transport }
        if calls == failAt && mode == "context" { throw ManagedEmbeddingError.contextExceeded }
        return inputs.map { input in
            var vector = [Float](repeating: 0, count: 768); vector[0] = 1
            if input.formatted.contains("不相关") { vector[0] = 0; vector[1] = 1 }
            if mode == "nearUnit" { vector[0] = 0.9998 }
            if calls == failAt && mode == "dimension" { vector.removeLast() }
            if calls == failAt && mode == "nan" { vector[0] = .nan }
            if calls == failAt && mode == "norm" { vector[0] = 2 }
            return EmbeddingResult(input: input, vector: vector, model: SourceEmbeddingSpace.managed.model,
                checkpointSHA256: calls == failAt && mode == "space" ? "wrong" : SourceEmbeddingSpace.managed.checkpointSHA256,
                runtimeRevision: SourceEmbeddingSpace.managed.runtimeRevision, executionLocation: .onDevice)
        }
    }
    func stop() { stops += 1; release() }
    func stopCount() -> Int { stops }
}
