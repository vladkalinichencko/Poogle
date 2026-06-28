import Foundation

struct SearchResult: Identifiable, Sendable {
    let path: String
    let title: String
    let section: String
    let snippet: String
    let score: Double

    var id: String {
        path
    }
}
