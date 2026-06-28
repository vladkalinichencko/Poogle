import Foundation
import Testing
@testable import Poogle

@Test
func embeddedPaperCanBeFoundAndSkippedWhenUnchanged() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let database = try IndexDatabase(
        url: directory.appending(path: "index.sqlite")
    )
    let file = FileFingerprint(
        documentID: "attention-hash",
        path: "/papers/attention.pdf",
        modifiedAt: 12,
        byteCount: 34
    )
    let document = ParsedDocument(
        url: URL(filePath: file.path),
        title: "Attention Is All You Need",
        abstract: "A transformer architecture",
        sections: [
            ParsedSection(
                title: "Model Architecture",
                text: "The encoder maps an input sequence to representations."
            )
        ]
    )
    let embedded = EmbeddedDocument(
        document: document,
        chunks: [
            EmbeddedChunk(
                heading: "Model Architecture",
                text: document.sections[0].text,
                embedding: [0, 1]
            )
        ]
    )

    try await database.replace(embedded, fingerprint: file)

    #expect(try await database.prepareSync([file]).isEmpty)
    #expect(try await database.documentCount() == 1)
    #expect(try await database.lexicalSearch("encoder").first?.path == file.path)
    #expect(try await database.documentVectors().count == 1)
    #expect(try await database.chunkVectors().first?.embedding == [0, 1])
}

@Test
func modifiedPaperNeedsIndexing() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let database = try IndexDatabase(
        url: directory.appending(path: "index.sqlite")
    )
    let original = FileFingerprint(
        documentID: "paper-hash",
        path: "/papers/paper.pdf",
        modifiedAt: 1,
        byteCount: 2
    )
    let document = ParsedDocument(
        url: URL(filePath: original.path),
        title: "Paper",
        abstract: "",
        sections: []
    )
    try await database.replace(
        EmbeddedDocument(
            document: document,
            chunks: []
        ),
        fingerprint: original
    )
    let modified = FileFingerprint(
        documentID: "modified-paper-hash",
        path: original.path,
        modifiedAt: 2,
        byteCount: 3
    )

    #expect(try await database.prepareSync([modified]) == [modified])
}

@Test
func movedPaperReusesExistingEmbeddings() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let database = try IndexDatabase(
        url: directory.appending(path: "index.sqlite")
    )
    let original = FileFingerprint(
        documentID: "stable-hash",
        path: "/papers/old/paper.pdf",
        modifiedAt: 1,
        byteCount: 2
    )
    let document = ParsedDocument(
        url: URL(filePath: original.path),
        title: "Moved Paper",
        abstract: "",
        sections: []
    )
    try await database.replace(
        EmbeddedDocument(
            document: document,
            chunks: []
        ),
        fingerprint: original
    )
    let moved = FileFingerprint(
        documentID: original.documentID,
        path: "/papers/new/paper.pdf",
        modifiedAt: 2,
        byteCount: original.byteCount
    )

    #expect(try await database.prepareSync([moved]).isEmpty)
    try await database.removeMissing(paths: [moved.path])
    #expect(try await database.documentCount() == 1)
    #expect(try await database.documentVectors().first?.path == moved.path)
}

@Test
func duplicatePathsShareOneDocument() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let database = try IndexDatabase(
        url: directory.appending(path: "index.sqlite")
    )
    let first = FileFingerprint(
        documentID: "same-hash",
        path: "/papers/first.pdf",
        modifiedAt: 1,
        byteCount: 2
    )
    let document = ParsedDocument(
        url: URL(filePath: first.path),
        title: "Duplicate",
        abstract: "",
        sections: []
    )
    try await database.replace(
        EmbeddedDocument(
            document: document,
            chunks: []
        ),
        fingerprint: first
    )
    let second = FileFingerprint(
        documentID: first.documentID,
        path: "/papers/second.pdf",
        modifiedAt: 1,
        byteCount: 2
    )

    #expect(try await database.prepareSync([first, second]).isEmpty)
    #expect(try await database.documentCount() == 1)
}

@Test
func newDuplicatePathsNeedOneEmbeddingAndKeepBothLocations() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let database = try IndexDatabase(
        url: directory.appending(path: "index.sqlite")
    )
    let files = [
        FileFingerprint(
            documentID: "same-new-hash",
            path: "/papers/first.pdf",
            modifiedAt: 1,
            byteCount: 2
        ),
        FileFingerprint(
            documentID: "same-new-hash",
            path: "/papers/second.pdf",
            modifiedAt: 1,
            byteCount: 2
        ),
    ]
    let pendingPaths = try await database.prepareSync(files)
    let pendingDocuments = DocumentScanner().uniqueDocuments(
        in: pendingPaths
    )
    #expect(pendingDocuments.count == 1)

    let representative = try #require(pendingDocuments.first)
    let document = ParsedDocument(
        url: URL(filePath: representative.path),
        title: "One document",
        abstract: "",
        sections: []
    )
    try await database.replace(
        EmbeddedDocument(
            document: document,
            chunks: []
        ),
        fingerprint: representative
    )

    #expect(try await database.prepareSync(files).isEmpty)
    #expect(try await database.documentCount() == 1)
}
