import Foundation
import Testing
@testable import Poogle

@Test
func weakSemanticQueryReturnsNoDocuments() async throws {
    let database = try searchDatabase()
    try await insertSearchDocument(
        database,
        id: "paper",
        path: "/papers/paper.pdf",
        bodyEmbedding: [1, 0]
    )
    let model = StubSearchModel(
        query: QueryEmbeddingResponse(
            bodyEmbedding: [0, 1]
        ),
        rerankScores: [1]
    )

    let results = try await SearchEngine(
        database: database,
        worker: model
    ).search("unrelated")

    #expect(results.isEmpty)
}

@Test
func retrievalSignalsDetermineFinalResults() async throws {
    let database = try searchDatabase()
    try await insertSearchDocument(
        database,
        id: "relevant",
        path: "/papers/relevant.pdf",
        bodyEmbedding: [1, 0]
    )
    try await insertSearchDocument(
        database,
        id: "related",
        path: "/papers/related.pdf",
        bodyEmbedding: [0.8, 0.6]
    )
    let model = StubSearchModel(
        query: QueryEmbeddingResponse(
            bodyEmbedding: [1, 0]
        ),
        rerankScores: [0.9, 0.05]
    )

    let results = try await SearchEngine(
        database: database,
        worker: model
    ).search("relevant method")

    #expect(results.count == 1)
    #expect(results.first?.path == "/papers/relevant.pdf")
    #expect(model.rerankCallCount == 1)
}

@Test
func rerankerMustReturnOneScorePerDocument() async throws {
    let database = try searchDatabase()
    try await insertSearchDocument(
        database,
        id: "paper",
        path: "/papers/paper.pdf",
        bodyEmbedding: [1, 0]
    )
    let model = StubSearchModel(
        query: QueryEmbeddingResponse(bodyEmbedding: [1, 0]),
        rerankScores: []
    )
    let engine = SearchEngine(database: database, worker: model)

    await #expect(
        throws: SearchEngineError.invalidRerankResponse(
            expected: 1,
            actual: 0
        )
    ) {
        try await engine.search("paper")
    }
}

@Test
func hyphenatedExactQueryIsNotDilutedByAliases() async throws {
    let database = try searchDatabase()
    try await insertSearchDocument(
        database,
        id: "t-sne",
        path: "/papers/t-sne.pdf",
        bodyEmbedding: [0, 1]
    )
    let model = StubSearchModel(
        query: QueryEmbeddingResponse(bodyEmbedding: [1, 0]),
        rerankScores: [0.9]
    )

    let results = try await SearchEngine(
        database: database,
        worker: model
    ).search("t-SNE")

    #expect(results.first?.path == "/papers/t-sne.pdf")
}

@Test
func noisyCaptionDoesNotWinDisplayedSnippet() async throws {
    let database = try searchDatabase()
    let document = ParsedDocument(
        url: URL(filePath: "/papers/memory.pdf"),
        title: "Hybrid computing using a neural network with dynamic external memory",
        abstract: "",
        sections: [
            ParsedSection(
                title: "Body",
                text: "Figure 6 A:5a3 A:4r3 T? # # # # # planned action decodings e t-SNE location goal labels c board states 5 1 2 3."
            ),
            ParsedSection(
                title: "Body",
                text: "Across trials, we create a dataset of these vectors and perform t-SNE dimensionality reduction down to two dimensions."
            )
        ]
    )
    try await database.replace(
        EmbeddedDocument(
            document: document,
            chunks: [
                EmbeddedChunk(
                    heading: "Body",
                    text: document.sections[0].text,
                    embedding: [1, 0]
                ),
                EmbeddedChunk(
                    heading: "Body",
                    text: document.sections[1].text,
                    embedding: [0.99, 0.01]
                )
            ]
        ),
        fingerprint: FileFingerprint(
            documentID: "memory",
            path: "/papers/memory.pdf",
            modifiedAt: 1,
            byteCount: 1
        )
    )
    let model = StubSearchModel(
        query: QueryEmbeddingResponse(
            bodyEmbedding: [1, 0]
        ),
        rerankScores: [0.9]
    )

    let results = try await SearchEngine(
        database: database,
        worker: model
    ).search("t-SNE")

    #expect(results.first?.snippet.contains("Across trials") == true)
}

private func searchDatabase() throws -> IndexDatabase {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return try IndexDatabase(
        url: directory.appending(path: "index.sqlite")
    )
}

private func insertSearchDocument(
    _ database: IndexDatabase,
    id: String,
    path: String,
    bodyEmbedding: [Float]
) async throws {
    let document = ParsedDocument(
        url: URL(filePath: path),
        title: id,
        abstract: "Scientific abstract for \(id)",
        sections: [
            ParsedSection(
                title: "Body",
                text: "Scientific passage for \(id)"
            )
        ]
    )
    try await database.replace(
        EmbeddedDocument(
            document: document,
            chunks: [
                EmbeddedChunk(
                    heading: "Body",
                    text: document.sections[0].text,
                    embedding: bodyEmbedding
                )
            ]
        ),
        fingerprint: FileFingerprint(
            documentID: id,
            path: path,
            modifiedAt: 1,
            byteCount: 1
        )
    )
}

private final class StubSearchModel: SearchModel, @unchecked Sendable {
    let query: QueryEmbeddingResponse
    let rerankScores: [Double]
    var rerankCallCount = 0

    init(
        query: QueryEmbeddingResponse,
        rerankScores: [Double]
    ) {
        self.query = query
        self.rerankScores = rerankScores
    }

    func embed(query: String) throws -> QueryEmbeddingResponse {
        self.query
    }

    func rerank(
        query: String,
        documents: [RerankDocument]
    ) throws -> [Double] {
        rerankCallCount += 1
        return Array(rerankScores.prefix(documents.count))
    }
}
