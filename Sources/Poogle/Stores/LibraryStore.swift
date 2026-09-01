import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
    var folder: URL?
    var query = ""
    var results: [SearchResult] = []
    var state: IndexState = .empty
    var searchState: SearchState = .idle
    var searchProgress: SearchProgress?
    var skippedFiles: [String] = []

    private let indexer: LibraryIndexer
    private let worker: EmbeddingWorker
    private let database: IndexDatabase
    private let searchEngine: SearchEngine
    private var indexingTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(
        scanner: DocumentScanner,
        worker: EmbeddingWorker,
        database: IndexDatabase,
        searchEngine: SearchEngine
    ) {
        indexer = LibraryIndexer(
            scanner: scanner,
            worker: worker,
            database: database
        )
        self.worker = worker
        self.database = database
        self.searchEngine = searchEngine
        folder = LibrarySettings.folder
        Task {
            do {
                let count = try await database.documentCount()
                if count > 0 {
                    state = .ready(documentCount: count)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func chooseFolder() {
        guard indexingTask == nil else {
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK else {
            return
        }

        folder = panel.url
        LibrarySettings.save(folder: panel.url)
        results = []
        searchState = .idle
        skippedFiles = []
        state = .empty
    }

    func index(rebuild: Bool = false) {
        guard let folder, indexingTask == nil else {
            return
        }

        indexingTask = Task {
            do {
                skippedFiles = []
                _ = try await indexer.sync(
                    folder: folder,
                    rebuild: rebuild,
                    onState: { newState in
                        await MainActor.run { [weak self] in
                            self?.state = newState
                        }
                    },
                    onSkipped: { fileName in
                        await MainActor.run { [weak self] in
                            self?.skippedFiles.append(fileName)
                        }
                    }
                )
            } catch is CancellationError {
                state = .ready(documentCount: (try? await database.documentCount()) ?? 0)
            } catch {
                state = .failed(error.localizedDescription)
            }
            indexingTask = nil
        }
    }

    func stop() {
        switch state {
        case let .indexing(completed, total, _):
            state = .stopping(completed: completed, total: total)
        case .scanning, .preparing:
            state = .stopping(completed: 0, total: 0)
        default:
            return
        }
        indexingTask?.cancel()
        worker.stop()
    }

    func search() {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = []
            searchState = .idle
            return
        }
        searchTask?.cancel()
        searchState = .searching
        searchProgress = .embedding
        searchTask = Task {
            do {
                let found = try await searchEngine.search(query) { progress in
                    Task { @MainActor [weak self] in
                        self?.searchProgress = progress
                    }
                }
                try Task.checkCancellation()
                results = found
                searchProgress = nil
                searchState = found.isEmpty ? .noResults : .results
            } catch is CancellationError {
                return
            } catch {
                searchProgress = nil
                searchState = .failed(error.localizedDescription)
            }
        }
    }

    func open(_ result: SearchResult) {
        NSWorkspace.shared.open(URL(filePath: result.path))
    }

    func clearSearch() {
        searchTask?.cancel()
        query = ""
        results = []
        searchState = .idle
    }

    func reveal(_ result: SearchResult) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(filePath: result.path)
        ])
    }
}
