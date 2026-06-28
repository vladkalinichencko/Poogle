import Accelerate
import Foundation

actor SearchEngine {
    private let database: IndexDatabase
    private let model: any SearchModel

    init(database: IndexDatabase, worker: any SearchModel) {
        self.database = database
        model = worker
    }

    func search(
        _ query: String,
        onProgress: @Sendable (SearchProgress) -> Void = { _ in }
    ) async throws -> [SearchResult] {
        let profile = QueryProfile(query)
        guard profile.hasMeaningfulToken else {
            return []
        }
        onProgress(.embedding)
        let queryEmbedding = try await Task.detached {
            try self.model.embed(query: query)
        }.value
        onProgress(.retrieving)
        async let documents = database.documentVectors()
        async let chunks = database.chunkVectors()
        async let lexical = database.lexicalSearch(query)

        let documentRows = try await documents
        let chunkRows = try await chunks
        let lexicalRows = try await lexical
        var candidates = documentCandidates(
            documentRows,
            profile: profile
        )
        addBodyScores(
            chunkRows,
            queryEmbedding: queryEmbedding.bodyEmbedding,
            profile: profile,
            candidates: &candidates
        )

        addLexicalScores(lexicalRows, profile: profile, candidates: &candidates)

        let pool = rerankPool(candidates)
        guard !pool.isEmpty else {
            return []
        }

        let rerankDocuments = pool.map {
            RerankDocument(
                title: $0.title,
                abstract: $0.abstract,
                passage: rerankPassage($0)
            )
        }
        let total = rerankDocuments.count
        onProgress(.ranking(done: 0, total: total))

        // Rerank in small batches so the UI can report real progress; the
        // cross-encoder scores each document independently, so batching does
        // not change the result, only when intermediate progress is reported.
        var scores: [Double] = []
        var start = 0
        while start < total {
            try Task.checkCancellation()
            let end = min(start + SearchCalibration.rerankBatchSize, total)
            let batch = Array(rerankDocuments[start..<end])
            let batchScores = try await Task.detached { [model] in
                try model.rerank(query: query, documents: batch)
            }.value
            guard batchScores.count == batch.count else {
                throw SearchEngineError.invalidRerankResponse(
                    expected: batch.count,
                    actual: batchScores.count
                )
            }
            scores.append(contentsOf: batchScores)
            onProgress(.ranking(done: scores.count, total: total))
            start = end
        }

        return rankedResults(pool, scores: scores)
    }

    /// Recall stage. Admits documents that are topically close on the Qwen body
    /// vector (the signal that actually reads passage content) or carry a strong
    /// exact/lexical match, then keeps the highest-recall ceiling for the
    /// cross-encoder reranker to judge. A document-level paper embedding is not
    /// used: within a single field it clusters every paper together, which only
    /// inflates the candidate set without separating real relevance.
    private func rerankPool(_ candidates: [String: Candidate]) -> [Candidate] {
        Array(
            candidates.values
                .filter(admitForRerank)
                .sorted { left, right in
                    let leftScore = retrievalScore(left)
                    let rightScore = retrievalScore(right)
                    return leftScore == rightScore
                        ? left.title < right.title
                        : leftScore > rightScore
                }
                .prefix(SearchCalibration.rerankCeiling)
        )
    }

    private func admitForRerank(_ candidate: Candidate) -> Bool {
        candidate.body >= SearchCalibration.qwenRetrievalFloor
            || exactEvidence(candidate) >= SearchCalibration.exactAdmitMinimum
    }

    private func retrievalScore(_ candidate: Candidate) -> Double {
        max(max(candidate.body, 0), exactEvidence(candidate))
    }

    private func exactEvidence(_ candidate: Candidate) -> Double {
        max(
            max(candidate.titleExact, candidate.abstractExact),
            max(candidate.bodyExact, boundedLexicalScore(candidate.text))
        )
    }

    private func rerankPassage(_ candidate: Candidate) -> String {
        if !candidate.passage.isEmpty, !isNoisyEvidence(candidate.passage) {
            return candidate.passage
        }
        if !candidate.abstract.isEmpty {
            return candidate.abstract
        }
        if !candidate.passage.isEmpty {
            return candidate.passage
        }
        return candidate.title
    }

    private func rankedResults(
        _ pool: [Candidate],
        scores: [Double]
    ) -> [SearchResult] {
        var seen: Set<String> = []
        return zip(pool, scores)
            .filter { $0.1 >= SearchCalibration.rerankMinimum }
            .sorted { $0.1 > $1.1 }
            .filter { seen.insert(dedupKey($0.0)).inserted }
            .map { candidate, score in
                SearchResult(
                    path: candidate.path,
                    title: Self.displayText(candidate.title),
                    section: candidate.heading,
                    snippet: Self.displayText(displaySnippet(candidate)),
                    score: score
                )
            }
    }

    private func dedupKey(_ candidate: Candidate) -> String {
        let title = Self.normalizedSearchText(candidate.title)
        let abstract = Self.normalizedSearchText(candidate.abstract)
            .prefix(160)
        return title + "|" + abstract
    }

    private func documentCandidates(
        _ rows: [DocumentVector],
        profile: QueryProfile
    ) -> [String: Candidate] {
        Dictionary(uniqueKeysWithValues: rows.map {
            (
                $0.documentID,
                Candidate(
                    path: $0.path,
                    title: $0.title,
                    abstract: $0.abstract,
                    titleExact: exactScore($0.title, profile: profile),
                    abstractExact: exactScore($0.abstract, profile: profile)
                )
            )
        })
    }

    private func addBodyScores(
        _ rows: [ChunkVector],
        queryEmbedding: [Float],
        profile: QueryProfile,
        candidates: inout [String: Candidate]
    ) {
        // Pass 1 is cheap (cosine only) and runs over every chunk — often 100k+.
        // Degenerate chunks were filtered out at the database level, so this just
        // records the best chunk per document by cosine.
        var bestIndex: [String: Int] = [:]
        var bestCosine: [String: Double] = [:]
        for index in rows.indices {
            let row = rows[index]
            guard candidates[row.documentID] != nil else {
                continue
            }
            let score = cosine(row.embedding, queryEmbedding)
            if score > bestCosine[row.documentID] ?? -.infinity {
                bestCosine[row.documentID] = score
                bestIndex[row.documentID] = index
            }
        }
        replaceNoisyMatches(
            rows,
            queryEmbedding: queryEmbedding,
            bestIndex: &bestIndex,
            bestCosine: &bestCosine
        )

        // Pass 2 runs the expensive string scoring only on the one chunk we keep
        // per document — at most a few thousand calls instead of 100k+.
        for (documentID, index) in bestIndex {
            let row = rows[index]
            candidates[documentID]?.body = bestCosine[documentID] ?? 0
            candidates[documentID]?.bodyExact = exactScore(row.text, profile: profile)
            candidates[documentID]?.heading = row.heading
            candidates[documentID]?.passage = row.text
            candidates[documentID]?.snippet = snippet(row.text)
        }
    }

    private func replaceNoisyMatches(
        _ rows: [ChunkVector],
        queryEmbedding: [Float],
        bestIndex: inout [String: Int],
        bestCosine: inout [String: Double]
    ) {
        let noisyDocuments = Set(
            bestIndex.compactMap { documentID, index in
                isNoisyEvidence(rows[index].text) ? documentID : nil
            }
        )
        guard !noisyDocuments.isEmpty else {
            return
        }

        var cleanIndex: [String: Int] = [:]
        var cleanCosine: [String: Double] = [:]
        for index in rows.indices {
            let row = rows[index]
            guard noisyDocuments.contains(row.documentID),
                  !isNoisyEvidence(row.text) else {
                continue
            }
            let score = cosine(row.embedding, queryEmbedding)
            if score > cleanCosine[row.documentID] ?? -.infinity {
                cleanCosine[row.documentID] = score
                cleanIndex[row.documentID] = index
            }
        }

        for documentID in noisyDocuments {
            bestIndex[documentID] = cleanIndex[documentID]
            bestCosine[documentID] = cleanCosine[documentID]
        }
    }

    private func addLexicalScores(
        _ rows: [LexicalHit],
        profile: QueryProfile,
        candidates: inout [String: Candidate]
    ) {
        for row in rows {
            if row.score > candidates[row.documentID]?.text ?? -.infinity {
                candidates[row.documentID]?.text = row.score
                if candidates[row.documentID]?.bodyExact ?? 0 < SearchCalibration.exactSnippetMinimum {
                    candidates[row.documentID]?.heading = row.heading
                    candidates[row.documentID]?.snippet = row.snippet
                    candidates[row.documentID]?.bodyExact = exactScore(
                        row.snippet,
                        profile: profile
                    )
                }
            }
        }
    }

    private func cosine(_ left: [Float], _ right: [Float]) -> Double {
        guard left.count == right.count, !left.isEmpty else {
            return 0
        }
        var value: Float = 0
        vDSP_dotpr(left, 1, right, 1, &value, vDSP_Length(left.count))
        return Double(value)
    }

    private func snippet(_ text: String) -> String {
        let clean = text
            .split(whereSeparator: \.isWhitespace)
            .prefix(55)
            .joined(separator: " ")
        return clean.count < text.count ? clean + "…" : clean
    }

    private func displaySnippet(_ candidate: Candidate) -> String {
        let abstract = snippet(candidate.abstract)
        let body = candidate.snippet
        if candidate.titleExact > 0 || candidate.abstractExact > candidate.bodyExact {
            if !abstract.isEmpty {
                return abstract
            }
        }
        if !body.isEmpty, !isNoisyEvidence(body) {
            return body
        }
        if !abstract.isEmpty {
            return abstract
        }
        return body
    }

    private func exactScore(_ text: String, profile: QueryProfile) -> Double {
        let normalized = Self.normalizedSearchText(text)
        let hits = profile.terms.filter {
            normalized.contains(" \($0) ")
        }.count
        guard !profile.terms.isEmpty else {
            return 0
        }
        return Double(hits) / Double(profile.terms.count)
    }

    /// Decomposes compatibility ligatures (ﬁ, ﬀ, ﬄ …) into plain ASCII so text
    /// extracted before Unicode normalization still renders correctly.
    private static func displayText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    private static func normalizedSearchText(_ text: String) -> String {
        let words = text
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber || character == "-"
                    ? character
                    : " "
            }
        return " " + String(words).split(
            whereSeparator: \.isWhitespace
        ).joined(separator: " ") + " "
    }

    private func isNoisyEvidence(_ text: String) -> Bool {
        snippetNoiseScore(text) >= SearchCalibration.noisySnippetMinimum
    }

    /// A chunk that is mostly numbers, symbols, or tiny fragments — a flattened
    /// table, equation grid, or stray glyph. The bi-encoder gives such text an
    /// unreliably high cosine to many queries, so it must never drive retrieval
    /// or become a document's matched passage.
    private func snippetNoiseScore(_ text: String) -> Double {
        let lower = text.lowercased()
        let firstWords = lower
            .split(whereSeparator: \.isWhitespace)
            .prefix(12)
            .joined(separator: " ")
        let characterCount = max(text.count, 1)
        let numericDensity = Double(text.filter(\.isNumber).count)
            / Double(characterCount)
        let punctuationDensity = Double(
            text.filter { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }.count
        ) / Double(characterCount)
        var score = 0.0

        if firstWords.contains("figure")
            || firstWords.contains("fig.")
            || firstWords.contains("table")
            || firstWords.contains("appendix") {
            score += 0.45
        }
        if lower.contains("references")
            || lower.contains("proceedings")
            || lower.contains("available:")
            || lower.contains("http://")
            || lower.contains("https://") {
            score += 0.35
        }
        if numericDensity > 0.22 {
            score += 0.35
        }
        if punctuationDensity > 0.18 {
            score += 0.20
        }
        if text.filter({ $0 == "," }).count >= 8 {
            score += 0.20
        }
        return min(score, 1.0)
    }

    private func boundedLexicalScore(_ score: Double) -> Double {
        guard score.isFinite, score > 0 else {
            return 0
        }
        return min(score, SearchCalibration.lexicalScoreCap)
            / SearchCalibration.lexicalScoreCap
    }
}

private enum SearchCalibration {
    /// Minimum Qwen body cosine for a document to enter the rerank pool. Below
    /// this the query is treated as topically outside the document.
    static let qwenRetrievalFloor = 0.55
    /// Fraction of query terms that must match exactly to admit a document that
    /// the Qwen vector missed (precise term or phrase lookups).
    static let exactAdmitMinimum = 0.50
    static let rerankCeiling = 64
    static let rerankBatchSize = 4
    static let rerankMinimum = 0.10
    static let exactSnippetMinimum = 0.50
    static let noisySnippetMinimum = 0.45
    static let lexicalScoreCap = 8.0
}

private struct Candidate {
    let path: String
    let title: String
    let abstract: String
    var titleExact: Double
    var abstractExact: Double
    var body = -Double.infinity
    var bodyExact = 0.0
    var text = -Double.infinity
    var heading = ""
    var passage = ""
    var snippet = ""
}

private struct QueryProfile {
    let terms: [String]

    init(_ query: String) {
        terms = Array(
            Set(
                query.lowercased()
                    .split {
                        !$0.isLetter && !$0.isNumber && $0 != "-"
                    }
                    .map(String.init)
                    .filter { $0.count >= 2 }
            )
        ).sorted()
    }

    var hasMeaningfulToken: Bool {
        !terms.isEmpty
    }
}

enum SearchEngineError: LocalizedError, Equatable {
    case invalidRerankResponse(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidRerankResponse(expected, actual):
            "The reranker returned \(actual) scores for \(expected) documents."
        }
    }
}
