import CSQLite
import Foundation

actor IndexDatabase {
    nonisolated(unsafe) private let database: OpaquePointer

    init(url: URL? = nil) throws {
        let databaseURL = try url ?? Self.defaultURL()
        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            throw DatabaseError.open
        }
        database = handle
        try Self.execute(database, sql: """
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS documents (
                document_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                abstract TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS locations (
                path TEXT PRIMARY KEY,
                document_id TEXT NOT NULL,
                modified_at REAL NOT NULL,
                byte_count INTEGER NOT NULL,
                FOREIGN KEY(document_id) REFERENCES documents(document_id)
                    ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS locations_document_id
                ON locations(document_id);
            CREATE TABLE IF NOT EXISTS chunks (
                id INTEGER PRIMARY KEY,
                document_id TEXT NOT NULL,
                heading TEXT NOT NULL,
                text TEXT NOT NULL,
                embedding BLOB NOT NULL,
                FOREIGN KEY(document_id) REFERENCES documents(document_id)
                    ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS chunks_document_id
                ON chunks(document_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS search_text USING fts5(
                document_id UNINDEXED,
                heading,
                text
            );
            """)
    }

    deinit {
        sqlite3_close(database)
    }

    func prepareSync(_ files: [FileFingerprint]) throws -> [FileFingerprint] {
        let locations = try indexedLocations()
        let documentIDs = try indexedDocumentIDs()
        var pending: [FileFingerprint] = []

        try Self.execute(database, sql: "BEGIN IMMEDIATE")
        do {
            for file in files {
                if locations[file.path] == LocationValue(
                    documentID: file.documentID,
                    modifiedAt: file.modifiedAt,
                    byteCount: file.byteCount
                ) {
                    continue
                }
                if documentIDs.contains(file.documentID) {
                    try upsertLocation(file)
                } else {
                    pending.append(file)
                }
            }
            try Self.execute(database, sql: "COMMIT")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
        return pending
    }

    func replace(_ embedded: EmbeddedDocument, fingerprint: FileFingerprint) throws {
        try Self.execute(database, sql: "BEGIN IMMEDIATE")
        do {
            if try !documentExists(fingerprint.documentID) {
                try insertDocument(embedded, documentID: fingerprint.documentID)
                try insertChunks(embedded, documentID: fingerprint.documentID)
                try insertSearchText(
                    embedded.document,
                    documentID: fingerprint.documentID
                )
            }
            try upsertLocation(fingerprint)
            try Self.execute(database, sql: "COMMIT")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    func removeMissing(paths: Set<String>) throws {
        let indexedPaths = Set(try indexedLocations().keys)
        try Self.execute(database, sql: "BEGIN IMMEDIATE")
        do {
            for path in indexedPaths.subtracting(paths) {
                try deleteLocation(path)
            }
            try deleteOrphanDocuments()
            try Self.execute(database, sql: "COMMIT")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    func rebuild() throws {
        try Self.execute(database, sql: """
            DELETE FROM search_text;
            DELETE FROM locations;
            DELETE FROM chunks;
            DELETE FROM documents;
            """)
    }

    func documentCount() throws -> Int {
        try integer("SELECT COUNT(*) FROM documents")
    }

    func documentVectors() throws -> [DocumentVector] {
        let sql = """
            SELECT d.document_id, MIN(l.path), d.title, d.abstract
            FROM documents d
            JOIN locations l ON l.document_id = d.document_id
            GROUP BY d.document_id
            """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        var rows: [DocumentVector] = []
        while try nextRow(statement) {
            rows.append(
                DocumentVector(
                    documentID: text(statement, 0),
                    path: text(statement, 1),
                    title: text(statement, 2),
                    abstract: text(statement, 3)
                )
            )
        }
        return rows
    }

    func chunkVectors() throws -> [ChunkVector] {
        let sql = """
            SELECT c.document_id, MIN(l.path), c.heading, c.text, c.embedding
            FROM chunks c
            JOIN locations l ON l.document_id = c.document_id
            GROUP BY c.id
            """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        var rows: [ChunkVector] = []
        while try nextRow(statement) {
            rows.append(
                ChunkVector(
                    documentID: text(statement, 0),
                    path: text(statement, 1),
                    heading: text(statement, 2),
                    text: text(statement, 3),
                    embedding: floats(statement, 4)
                )
            )
        }
        return rows
    }

    func lexicalSearch(_ query: String, limit: Int = 100) throws -> [LexicalHit] {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
        guard !terms.isEmpty else {
            return []
        }
        let sql = """
            SELECT s.document_id,
                   (SELECT MIN(path) FROM locations
                    WHERE document_id = s.document_id),
                   s.heading,
                   snippet(search_text, 2, '‹', '›', ' … ', 36),
                   -bm25(search_text)
            FROM search_text s
            WHERE search_text MATCH ?
            ORDER BY bm25(search_text)
            LIMIT ?
            """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        bind(terms, to: statement, at: 1)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var hits: [LexicalHit] = []
        while try nextRow(statement) {
            hits.append(
                LexicalHit(
                    documentID: text(statement, 0),
                    path: text(statement, 1),
                    heading: text(statement, 2),
                    snippet: text(statement, 3),
                    score: sqlite3_column_double(statement, 4)
                )
            )
        }
        return hits
    }

    private func insertDocument(
        _ embedded: EmbeddedDocument,
        documentID: String
    ) throws {
        let sql = """
            INSERT INTO documents(
                document_id, title, abstract
            ) VALUES (?, ?, ?)
            """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        bind(documentID, to: statement, at: 1)
        bind(embedded.document.title, to: statement, at: 2)
        bind(embedded.document.abstract, to: statement, at: 3)
        try step(statement)
    }

    private func insertChunks(
        _ embedded: EmbeddedDocument,
        documentID: String
    ) throws {
        let sql = """
            INSERT INTO chunks(document_id, heading, text, embedding)
            VALUES (?, ?, ?, ?)
            """
        for chunk in embedded.chunks {
            var statement: OpaquePointer?
            try prepare(sql, into: &statement)
            bind(documentID, to: statement, at: 1)
            bind(chunk.heading, to: statement, at: 2)
            bind(chunk.text, to: statement, at: 3)
            bind(chunk.embedding, to: statement, at: 4)
            try finalizeAfterStep(statement)
        }
    }

    private func insertSearchText(
        _ document: ParsedDocument,
        documentID: String
    ) throws {
        let sql = """
            INSERT INTO search_text(document_id, heading, text)
            VALUES (?, ?, ?)
            """
        let sections = [
            ParsedSection(title: document.title, text: document.abstract)
        ] + document.sections
        for section in sections where !section.text.isEmpty {
            var statement: OpaquePointer?
            try prepare(sql, into: &statement)
            bind(documentID, to: statement, at: 1)
            bind(section.title, to: statement, at: 2)
            bind(section.text, to: statement, at: 3)
            try finalizeAfterStep(statement)
        }
    }

    private func upsertLocation(_ file: FileFingerprint) throws {
        let sql = """
            INSERT INTO locations(path, document_id, modified_at, byte_count)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                document_id = excluded.document_id,
                modified_at = excluded.modified_at,
                byte_count = excluded.byte_count
            """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        bind(file.path, to: statement, at: 1)
        bind(file.documentID, to: statement, at: 2)
        sqlite3_bind_double(statement, 3, file.modifiedAt)
        sqlite3_bind_int64(statement, 4, file.byteCount)
        try step(statement)
    }

    private func indexedLocations() throws -> [String: LocationValue] {
        var statement: OpaquePointer?
        try prepare(
            "SELECT path, document_id, modified_at, byte_count FROM locations",
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        var values: [String: LocationValue] = [:]
        while try nextRow(statement) {
            values[text(statement, 0)] = LocationValue(
                documentID: text(statement, 1),
                modifiedAt: sqlite3_column_double(statement, 2),
                byteCount: sqlite3_column_int64(statement, 3)
            )
        }
        return values
    }

    private func indexedDocumentIDs() throws -> Set<String> {
        var statement: OpaquePointer?
        try prepare("SELECT document_id FROM documents", into: &statement)
        defer { sqlite3_finalize(statement) }
        var values: Set<String> = []
        while try nextRow(statement) {
            values.insert(text(statement, 0))
        }
        return values
    }

    private func documentExists(_ documentID: String) throws -> Bool {
        var statement: OpaquePointer?
        try prepare(
            "SELECT 1 FROM documents WHERE document_id = ? LIMIT 1",
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        bind(documentID, to: statement, at: 1)
        return try nextRow(statement)
    }

    private func deleteLocation(_ path: String) throws {
        var statement: OpaquePointer?
        try prepare("DELETE FROM locations WHERE path = ?", into: &statement)
        bind(path, to: statement, at: 1)
        try finalizeAfterStep(statement)
    }

    private func deleteOrphanDocuments() throws {
        try Self.execute(database, sql: """
            DELETE FROM search_text
            WHERE document_id NOT IN (
                SELECT DISTINCT document_id FROM locations
            );
            DELETE FROM documents
            WHERE document_id NOT IN (
                SELECT DISTINCT document_id FROM locations
            );
            """)
    }

    private func integer(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.step
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepare(_ sql: String, into statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepare
        }
    }

    private func step(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.step
        }
    }

    private func nextRow(_ statement: OpaquePointer?) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            true
        case SQLITE_DONE:
            false
        default:
            throw DatabaseError.step
        }
    }

    private func finalizeAfterStep(_ statement: OpaquePointer?) throws {
        do {
            try step(statement)
            sqlite3_finalize(statement)
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: [Float], to statement: OpaquePointer?, at index: Int32) {
        _ = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
        }
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        String(cString: sqlite3_column_text(statement, index))
    }

    private func floats(_ statement: OpaquePointer?, _ index: Int32) -> [Float] {
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return []
        }
        return Array(
            UnsafeBufferPointer(
                start: bytes.assumingMemoryBound(to: Float.self),
                count: byteCount / MemoryLayout<Float>.size
            )
        )
    }

    private static func defaultURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Poogle")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root.appending(path: "index-v3.sqlite")
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.execute
        }
    }

    private static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
}

struct DocumentVector: Sendable {
    let documentID: String
    let path: String
    let title: String
    let abstract: String
}

struct ChunkVector: Sendable {
    let documentID: String
    let path: String
    let heading: String
    let text: String
    let embedding: [Float]
}

struct LexicalHit: Sendable {
    let documentID: String
    let path: String
    let heading: String
    let snippet: String
    let score: Double
}

private struct LocationValue: Equatable {
    let documentID: String
    let modifiedAt: Double
    let byteCount: Int64
}

private enum DatabaseError: Error {
    case open
    case prepare
    case step
    case execute
}
