import Foundation

struct ParsedDocument: Sendable {
    let url: URL
    let title: String
    let abstract: String
    let sections: [ParsedSection]
}

struct ParsedSection: Sendable {
    let title: String
    let text: String
}

struct EmbeddedDocument: Sendable {
    let document: ParsedDocument
    let chunks: [EmbeddedChunk]
}

struct EmbeddedChunk: Sendable {
    let heading: String
    let text: String
    let embedding: [Float]
}

struct FileFingerprint: Sendable, Equatable {
    let documentID: String
    let path: String
    let modifiedAt: Double
    let byteCount: Int64
}
