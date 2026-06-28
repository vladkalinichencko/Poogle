import Foundation

struct DocumentEmbeddingResponse: Decodable {
    let title: String
    let abstract: String
    let chunks: [ChunkEmbeddingResponse]
}

struct ChunkEmbeddingResponse: Decodable {
    let heading: String
    let text: String
    let embedding: [Float]
}

struct QueryEmbeddingResponse: Decodable {
    let bodyEmbedding: [Float]
}

struct RerankDocument: Encodable, Sendable {
    let title: String
    let abstract: String
    let passage: String
}

struct RerankResponse: Decodable {
    let scores: [Double]
}

struct WorkerResponse<Result: Decodable>: Decodable {
    let result: Result?
    let error: String?
}
