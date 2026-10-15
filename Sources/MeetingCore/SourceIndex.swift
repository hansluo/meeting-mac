import Foundation
import CryptoKit
import PDFKit
import CSQLite
import Darwin

public enum SourceIndexError: Error, Equatable, Sendable {
    case busy, closed, database, unsupportedSchema, unsupportedFile, unreadableFile, invalidUTF8
    case fileTooLarge, textTooLarge, tooManyPages, tooManyChunks, emptyText, invalidPDF, nonRegularFile
    case invalidScope, sourceUnavailable, superseded, invalidVector, invalidEmbeddingSpace, invalidQuery
}

/// Offsets use UTF-16 code units, matching NSString/PDFKit. Page numbers are one-based.
public struct SourceAnchor: Codable, Equatable, Sendable {
    public let page: Int?
    public let utf16Offset: Int
    public let utf16Length: Int
    public let snapshotUTF16Offset: Int
}
public struct SourceEmbeddingSpace: Codable, Equatable, Sendable {
    public let model: String
    public let checkpointSHA256: String
    public let runtimeRevision: String
    public let dimensions: Int
    public let prefixRevision: Int
    public let chunkerRevision: Int
    public init(model: String, checkpointSHA256: String, runtimeRevision: String, dimensions: Int = 768, prefixRevision: Int = 1, chunkerRevision: Int = 1) {
        self.model = model; self.checkpointSHA256 = checkpointSHA256; self.runtimeRevision = runtimeRevision
        self.dimensions = dimensions; self.prefixRevision = prefixRevision; self.chunkerRevision = chunkerRevision
    }
    public static let managed = SourceEmbeddingSpace(model: ManagedEmbeddingService.model,
        checkpointSHA256: "0800cbac9c2064dde519420e75e512a83cb360de3ad5df176185dc69652fc515",
        runtimeRevision: "llama-server-ollama0.40.4:5f42e3e4457e869a152e2a8ee52084935b22d6c54c2077a44cb1d495d9eba18d")
    var key: String { get throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self).base64EncodedString()
    } }
}

/// Test/replaceability boundary. Production owns a ManagedEmbeddingService, including shutdown.
public struct SourceEmbeddingProvider: Sendable {
    public let space: SourceEmbeddingSpace
    let embed: @Sendable ([EmbeddingInput]) async throws -> [EmbeddingResult]
    let shutdown: @Sendable () async -> Void
    public init(space: SourceEmbeddingSpace, embed: @escaping @Sendable ([EmbeddingInput]) async throws -> [EmbeddingResult], shutdown: @escaping @Sendable () async -> Void) {
        self.space = space; self.embed = embed; self.shutdown = shutdown
    }
    public static func managed(service: ManagedEmbeddingService = ManagedEmbeddingService()) -> Self {
        Self(space: .managed, embed: { try await service.embed($0) }, shutdown: { await service.shutdown() })
    }
}
public struct SourceRecord: Equatable, Sendable {
    public let id: String
    public let sourceURI: String
    public let type: String
    public let accountScope: String
    public let activeRevisionID: String?
    public let status: String
    public let revoked: Bool
    public let deleted: Bool
}
public struct SourceDetail: Sendable {
    public let source: SourceRecord
    public let contentSHA256: String?
    public let parserRevision: Int?
    public let text: String?
    public let embeddingSpace: SourceEmbeddingSpace?
    public let chunks: [SourceChunk]
}
public struct SourceChunk: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let anchor: SourceAnchor
}
public struct SourceSearchHit: Sendable {
    public let sourceID: String
    public let revisionID: String
    public let chunkID: String
    public let sourceURI: String
    public let accountScope: String
    public let text: String
    public let anchor: SourceAnchor
    public let score: Double
    public let embeddingSpace: SourceEmbeddingSpace
}

/// A single admitted ingestion/query owns embedding; deletion/revocation remain available while it awaits.
/// No database transaction spans an await. All snapshots and vectors activate together.
public actor SourceIndex {
    public static let maximumFileBytes = 8 * 1024 * 1024
    public static let maximumTextBytes = 2 * 1024 * 1024
    public static let maximumPDFPages = 500
    public static let maximumChunks = 4096
    public static let parserRevision = 1
    private let db: SourceDatabase
    private let embedding: SourceEmbeddingProvider
    private var busy = false
    private var closed = false
    private var shutdownTask: Task<Void, Never>?
    public static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingMac", isDirectory: true).appendingPathComponent("sources.sqlite")
    }
    public init(databaseURL: URL = SourceIndex.defaultDatabaseURL, embedding: SourceEmbeddingProvider = .managed()) throws {
        guard embedding.space.dimensions == 768, embedding.space.prefixRevision == 1, embedding.space.chunkerRevision == 1 else { throw SourceIndexError.invalidEmbeddingSpace }
        self.embedding = embedding; db = try SourceDatabase(url: databaseURL)
    }
    public func list() throws -> [SourceRecord] { try checkOpen(); return try db.sources() }
    public func detail(sourceID: String) throws -> SourceDetail? {
        try checkOpen()
        guard let source = try db.source(sourceID), !source.deleted else { return nil }
        guard !source.revoked, let revision = source.activeRevisionID, let row = try db.rows("SELECT hash,parser,text,space FROM revisions WHERE id=?", [revision]).first else {
            return SourceDetail(source: source, contentSHA256: nil, parserRevision: nil, text: nil, embeddingSpace: nil, chunks: [])
        }
        guard let encodedSpace = Data(base64Encoded: row[3]),
              let space = try? JSONDecoder().decode(SourceEmbeddingSpace.self, from: encodedSpace) else { throw SourceIndexError.invalidEmbeddingSpace }
        let chunks = try db.rows("SELECT payload FROM chunks WHERE revision=? ORDER BY ordinal", [revision]).map { row in
            guard let chunk = try? JSONDecoder().decode(SourceChunk.self, from: Data(row[0].utf8)) else { throw SourceIndexError.database }
            return chunk
        }
        return SourceDetail(source: source, contentSHA256: row[0], parserRevision: Int(row[1]), text: row[2], embeddingSpace: space, chunks: chunks)
    }
    public func delete(sourceID: String) throws {
        try checkOpen()
        try db.transaction {
            try db.run("UPDATE sources SET deleted=1,epoch=epoch+1,active=NULL,status='deleted' WHERE id=?", [sourceID])
            try db.run("DELETE FROM revisions WHERE source=?", [sourceID])
        }
    }
    public func revoke(sourceID: String) throws {
        try checkOpen(); try db.run("UPDATE sources SET revoked=1,epoch=epoch+1,status='revoked' WHERE id=?", [sourceID])
    }
    public func ingest(file: URL, accountScope: String) async throws -> SourceRecord {
        try checkOpen(); guard !busy else { throw SourceIndexError.busy }
        guard !accountScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, accountScope.utf8.count <= 1024 else { throw SourceIndexError.invalidScope }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        let parsed = try SourceExtraction.read(file)
        let uri = file.standardizedFileURL.absoluteString, space = try embedding.space.key
        let existing = try db.rows("SELECT id,revoked,deleted FROM sources WHERE uri=? AND account=?", [uri, accountScope]).first
        if let existing, existing[1] == "1" || existing[2] == "1" { throw SourceIndexError.sourceUnavailable }
        let sourceID = existing?[0] ?? UUID().uuidString
        if let source = try db.source(sourceID), let revision = source.activeRevisionID,
           !(try db.rows("SELECT id FROM revisions WHERE id=? AND hash=? AND parser=? AND space=?", [revision, parsed.hash, String(Self.parserRevision), space])).isEmpty { return source }
        var epoch = 0
        try db.transaction {
            if let record = try db.source(sourceID), record.deleted || record.revoked { throw SourceIndexError.sourceUnavailable }
            if existing == nil { try db.run("INSERT INTO sources(id,uri,type,account,status) VALUES(?,?,?,?, 'pending')", [sourceID, uri, parsed.type, accountScope]) }
            try db.run("UPDATE sources SET epoch=epoch+1,status='indexing' WHERE id=?", [sourceID])
            epoch = try db.epoch(sourceID)
        }
        do {
            var vectors: [[Float]] = []
            let title = String(file.lastPathComponent.unicodeScalars.prefix(120))
            // One item per call bounds memory and lets cancellation/permissions intervene between chunks.
            for chunk in parsed.chunks {
                try Task.checkCancellation()
                let input = EmbeddingInput.document(title: title, text: chunk.text)
                let results = try await embedding.embed([input])
                try checkCurrent(sourceID, epoch: epoch)
                vectors.append(try validate(results, input: input))
            }
            try Task.checkCancellation(); try checkCurrent(sourceID, epoch: epoch)
            let revision = UUID().uuidString
            try db.transaction {
                try checkCurrent(sourceID, epoch: epoch)
                try db.run("INSERT INTO revisions(id,source,hash,parser,text,space) VALUES(?,?,?,?,?,?)", [revision, sourceID, parsed.hash, String(Self.parserRevision), parsed.text, space])
                for (ordinal, chunk) in parsed.chunks.enumerated() {
                    let payload = String(decoding: try JSONEncoder().encode(chunk), as: UTF8.self)
                    let vector = String(decoding: try JSONEncoder().encode(vectors[ordinal]), as: UTF8.self)
                    try db.run("INSERT INTO chunks(id,revision,ordinal,payload,vector) VALUES(?,?,?,?,?)", [chunk.id, revision, String(ordinal), payload, vector])
                }
                try db.run("UPDATE sources SET active=?,status='indexed' WHERE id=?", [revision, sourceID])
            }
            guard let committed = try db.source(sourceID) else { throw SourceIndexError.database }
            return committed
        } catch {
            if !closed { try? db.run("UPDATE sources SET status='failed' WHERE id=? AND epoch=? AND deleted=0 AND revoked=0", [sourceID, String(epoch)]) }
            throw error
        }
    }
    public func search(_ query: String, sourceIDs: Set<String>, accountScopes: Set<String>, limit: Int = 10) async throws -> [SourceSearchHit] {
        try checkOpen()
        guard !sourceIDs.isEmpty, !accountScopes.isEmpty else { return [] }
        guard limit > 0, limit <= 100, EmbeddingInput.query(query).valid else { throw SourceIndexError.invalidQuery }
        guard sourceIDs.count <= 1000, accountScopes.count <= 1000 else { throw SourceIndexError.invalidScope }
        guard !busy else { throw SourceIndexError.busy }
        busy = true; defer { busy = false }
        let input = EmbeddingInput.query(query)
        let results = try await embedding.embed([input])
        try Task.checkCancellation(); try checkOpen()
        let vector = try validate(results, input: input), space = try embedding.space.key
        // Read eligibility AFTER embedding. Actor does not suspend again before returning.
        let sources = sourceIDs.sorted(), accounts = accountScopes.sorted()
        let sourceSlots = Array(repeating: "?", count: sources.count).joined(separator: ",")
        let accountSlots = Array(repeating: "?", count: accounts.count).joined(separator: ",")
        let sql = "SELECT s.id,r.id,s.uri,s.account,c.payload,c.vector FROM sources s JOIN revisions r ON r.id=s.active JOIN chunks c ON c.revision=r.id WHERE s.deleted=0 AND s.revoked=0 AND r.space=? AND s.id IN (\(sourceSlots)) AND s.account IN (\(accountSlots))"
        let queryNorm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        var hits: [SourceSearchHit] = []
        try db.forEachRow(sql, [space] + sources + accounts) { row in
            try Task.checkCancellation()
            guard let chunk = try? JSONDecoder().decode(SourceChunk.self, from: Data(row[4].utf8)) else { throw SourceIndexError.database }
            guard let stored = try? JSONDecoder().decode([Float].self, from: Data(row[5].utf8)) else { throw SourceIndexError.invalidVector }
            try validateVector(stored)
            let dot = zip(vector, stored).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            let storedNorm = stored.reduce(0.0) { $0 + Double($1) * Double($1) }
            let score = max(-1, min(1, dot / sqrt(queryNorm * storedNorm)))
            hits.append(SourceSearchHit(sourceID: row[0], revisionID: row[1], chunkID: chunk.id, sourceURI: row[2], accountScope: row[3], text: chunk.text, anchor: chunk.anchor, score: score, embeddingSpace: embedding.space))
            hits.sort { $0.score == $1.score ? $0.chunkID < $1.chunkID : $0.score > $1.score }
            if hits.count > limit { hits.removeLast() }
        }
        return hits
    }

    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        closed = true
        let provider = embedding
        let drain = Task { await provider.shutdown() }
        shutdownTask = drain
        await drain.value
        db.close()
    }
    private func checkOpen() throws { if closed { throw SourceIndexError.closed } }
    private func checkCurrent(_ source: String, epoch: Int) throws {
        try checkOpen(); try Task.checkCancellation()
        guard let record = try db.source(source), !record.deleted, !record.revoked, try db.epoch(source) == epoch else { throw SourceIndexError.superseded }
    }
    private func validate(_ results: [EmbeddingResult], input: EmbeddingInput) throws -> [Float] {
        guard results.count == 1, results[0].input == input else { throw SourceIndexError.invalidVector }
        let result = results[0], expected = embedding.space
        guard result.model == expected.model, result.checkpointSHA256 == expected.checkpointSHA256,
              result.runtimeRevision == expected.runtimeRevision, result.executionLocation == .onDevice else { throw SourceIndexError.invalidEmbeddingSpace }
        try validateVector(result.vector); return result.vector
    }
    private func validateVector(_ vector: [Float]) throws {
        guard vector.count == 768, vector.allSatisfy(\.isFinite) else { throw SourceIndexError.invalidVector }
        let norm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard norm.isFinite, abs(norm - 1) < 0.001 else { throw SourceIndexError.invalidVector }
    }
}

private struct SourceExtraction {
    let type: String
    let hash: String
    let text: String
    let chunks: [SourceChunk]
    static func read(_ file: URL) throws -> Self {
        guard file.isFileURL else { throw SourceIndexError.unsupportedFile }
        let type = file.pathExtension.lowercased()
        guard ["txt", "md", "pdf"].contains(type) else { throw SourceIndexError.unsupportedFile }
        // O_NONBLOCK prevents named pipes/devices from hanging before the descriptor is checked.
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SourceIndexError.unreadableFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw SourceIndexError.unreadableFile }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw SourceIndexError.nonRegularFile }
        guard metadata.st_size <= SourceIndex.maximumFileBytes else { throw SourceIndexError.fileTooLarge }
        var data = Data()
        do {
            while data.count <= SourceIndex.maximumFileBytes {
                try Task.checkCancellation()
                let next = try handle.read(upToCount: min(65536, SourceIndex.maximumFileBytes + 1 - data.count)) ?? Data()
                if next.isEmpty { break }
                data.append(next)
            }
        } catch is CancellationError { throw CancellationError() } catch { throw SourceIndexError.unreadableFile }
        guard data.count <= SourceIndex.maximumFileBytes else { throw SourceIndexError.fileTooLarge }
        var pages: [(Int?, String)] = []
        if type == "pdf" {
            guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { throw SourceIndexError.invalidPDF }
            guard document.pageCount <= SourceIndex.maximumPDFPages else { throw SourceIndexError.tooManyPages }
            var extractedBytes = 0
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { throw SourceIndexError.invalidPDF }
                let text = page.string ?? ""
                extractedBytes += text.utf8.count + (index == 0 ? 0 : 1)
                guard extractedBytes <= SourceIndex.maximumTextBytes else { throw SourceIndexError.textTooLarge }
                pages.append((index + 1, text))
            }
        } else {
            guard let text = String(data: data, encoding: .utf8) else { throw SourceIndexError.invalidUTF8 }
            pages = [(nil, text)]
        }
        let text = pages.map(\.1).joined(separator: "\n")
        guard text.utf8.count <= SourceIndex.maximumTextBytes else { throw SourceIndexError.textTooLarge }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceIndexError.emptyText }
        var chunks: [SourceChunk] = [], snapshotOffset = 0
        for (page, content) in pages {
            var start = content.startIndex, pageOffset = 0
            while start < content.endIndex {
                try Task.checkCancellation()
                // Unicode scalar boundaries avoid splitting a UTF-16 surrogate. 384 scalars cap
                // UTF-8 at 1536 bytes; actual tokenizer limits remain enforced by the provider.
                let scalars = content.unicodeScalars
                let end = scalars.index(start, offsetBy: 384, limitedBy: scalars.endIndex) ?? scalars.endIndex
                let part = String(scalars[start..<end]), length = part.utf16.count
                // Blank spans remain in the immutable snapshot and offset accounting, but
                // carry no retrieval content and are invalid standalone embedding inputs.
                if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chunks.append(SourceChunk(id: UUID().uuidString, text: part, anchor: SourceAnchor(page: page, utf16Offset: pageOffset, utf16Length: length, snapshotUTF16Offset: snapshotOffset + pageOffset)))
                }
                guard chunks.count <= SourceIndex.maximumChunks else { throw SourceIndexError.tooManyChunks }
                pageOffset += length; start = end
            }
            snapshotOffset += content.utf16.count + 1
        }
        return Self(type: type, hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), text: text, chunks: chunks)
    }
}

/// Connection is only used synchronously by its owning SourceIndex actor.
private final class SourceDatabase {
    private var connection: OpaquePointer?
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { close(); throw SourceIndexError.database }
        do {
            sqlite3_busy_timeout(connection, 5000)
            try run("PRAGMA foreign_keys=ON")
            let version = try rows("PRAGMA user_version").first?[0] ?? "0"
            guard version == "0" || version == "1" else { throw SourceIndexError.unsupportedSchema }
            if version == "0" {
                try transaction {
                    try run("CREATE TABLE sources(id TEXT PRIMARY KEY,uri TEXT NOT NULL,type TEXT NOT NULL,account TEXT NOT NULL,active TEXT REFERENCES revisions(id) ON DELETE SET NULL,epoch INTEGER NOT NULL DEFAULT 0,status TEXT NOT NULL,deleted INTEGER NOT NULL DEFAULT 0,revoked INTEGER NOT NULL DEFAULT 0,UNIQUE(uri,account))")
                    try run("CREATE TABLE revisions(id TEXT PRIMARY KEY,source TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,hash TEXT NOT NULL,parser INTEGER NOT NULL,text TEXT NOT NULL,space TEXT NOT NULL)")
                    try run("CREATE TABLE chunks(id TEXT PRIMARY KEY,revision TEXT NOT NULL REFERENCES revisions(id) ON DELETE CASCADE,ordinal INTEGER NOT NULL,payload TEXT NOT NULL,vector TEXT NOT NULL,UNIQUE(revision,ordinal))")
                    try run("CREATE INDEX chunks_revision ON chunks(revision)")
                    try run("PRAGMA user_version=1")
                }
            }
            // A process may have ended during inference. No partial revision ever became active.
            try run("UPDATE sources SET status='failed',epoch=epoch+1 WHERE status='indexing'")
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() { if let connection { sqlite3_close_v2(connection) }; connection = nil }
    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do { try body(); try run("COMMIT") } catch { try? run("ROLLBACK"); throw error }
    }
    func run(_ sql: String, _ bindings: [String] = []) throws { _ = try rows(sql, bindings) }
    func rows(_ sql: String, _ bindings: [String] = []) throws -> [[String]] {
        var result: [[String]] = []
        try forEachRow(sql, bindings) { result.append($0) }
        return result
    }
    func forEachRow(_ sql: String, _ bindings: [String], body: ([String]) throws -> Void) throws {
        guard let connection else { throw SourceIndexError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SourceIndexError.database }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            let result = binding.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(binding.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else { throw SourceIndexError.database }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw SourceIndexError.database }
            let row = (0..<sqlite3_column_count(statement)).map { index -> String in
                guard let text = sqlite3_column_text(statement, index) else { return "" }
                return String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
            }
            try body(row)
        }
    }
    func source(_ id: String) throws -> SourceRecord? { try sources("WHERE id=?", [id]).first }
    func epoch(_ id: String) throws -> Int { guard let value = try rows("SELECT epoch FROM sources WHERE id=?", [id]).first.flatMap({ Int($0[0]) }) else { throw SourceIndexError.sourceUnavailable }; return value }
    func sources(_ suffix: String = "WHERE deleted=0", _ values: [String] = []) throws -> [SourceRecord] {
        try rows("SELECT id,uri,type,account,active,status,revoked,deleted FROM sources \(suffix) ORDER BY id", values).map {
            SourceRecord(id: $0[0], sourceURI: $0[1], type: $0[2], accountScope: $0[3], activeRevisionID: $0[4].isEmpty ? nil : $0[4], status: $0[5], revoked: $0[6] == "1", deleted: $0[7] == "1")
        }
    }
}
