import Foundation

enum IndexState: Equatable {
    case empty
    case scanning
    case preparing(total: Int)
    case indexing(completed: Int, total: Int, fileName: String)
    case stopping(completed: Int, total: Int)
    case ready(documentCount: Int)
    case failed(String)
}
