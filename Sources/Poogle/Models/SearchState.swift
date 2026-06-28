import Foundation

enum SearchState: Equatable {
    case idle
    case searching
    case results
    case noResults
    case failed(String)
}

enum SearchProgress: Equatable, Sendable {
    case embedding
    case retrieving
    case ranking(done: Int, total: Int)
}
