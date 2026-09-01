import AppKit
import SwiftUI

@main
enum PoogleMain {
    static func main() async {
        if CommandLine.arguments.dropFirst().contains("--mcp") {
            do {
                let database = try IndexDatabase()
                let worker = EmbeddingWorker()
                let server = MCPServer(
                    indexer: LibraryIndexer(
                        scanner: DocumentScanner(),
                        worker: worker,
                        database: database
                    ),
                    searchEngine: SearchEngine(
                        database: database,
                        worker: worker
                    )
                )
                await server.run()
            } catch {
                FileHandle.standardError.write(
                    Data("Poogle MCP failed: \(error.localizedDescription)\n".utf8)
                )
            }
            return
        }

        PoogleApp.main()
    }
}

struct PoogleApp: App {
    @State private var store: LibraryStore

    init() {
        do {
            let database = try IndexDatabase()
            let worker = EmbeddingWorker()
            _store = State(
                initialValue: LibraryStore(
                    scanner: DocumentScanner(),
                    worker: worker,
                    database: database,
                    searchEngine: SearchEngine(
                        database: database,
                        worker: worker
                    )
                )
            )
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup("Poogle") {
            ContentView(store: store)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 640)
    }
}
