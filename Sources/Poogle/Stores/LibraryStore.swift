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

    private let scanner: DocumentScanner
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
        self.scanner = scanner
        self.worker = worker
        self.database = database
        self.searchEngine = searchEngine
        if let path = UserDefaults.standard.string(forKey: "libraryFolder") {
            folder = URL(filePath: path)
        }
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
        UserDefaults.standard.set(panel.url?.path, forKey: "libraryFolder")
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
                state = .scanning
                skippedFiles = []
                if rebuild {
                    try await database.rebuild()
                }

                let scanner = scanner
                let worker = worker
                let files = try await Task.detached {
                    try scanner.fingerprints(in: folder)
                }.value
                try Task.checkCancellation()
                let uniqueFiles = scanner.uniqueDocuments(in: files)
                state = .preparing(total: uniqueFiles.count)
                let pendingPaths = try await database.prepareSync(files)
                let pending = scanner.uniqueDocuments(in: pendingPaths)
                try Task.checkCancellation()

                for (offset, fingerprint) in pending.enumerated() {
                    try Task.checkCancellation()
                    state = .indexing(
                        completed: offset,
                        total: pending.count,
                        fileName: URL(filePath: fingerprint.path).lastPathComponent
                    )
                    do {
                        let embedded = try await Task.detached {
                            try worker.embed(
                                URL(filePath: fingerprint.path)
                            )
                        }.value
                        try Task.checkCancellation()
                        try await database.replace(
                            embedded,
                            fingerprint: fingerprint
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        skippedFiles.append(
                            URL(filePath: fingerprint.path).lastPathComponent
                        )
                        worker.stop()
                    }
                }

                _ = try await database.prepareSync(files)
                try await database.removeMissing(
                    paths: Set(files.map(\.path))
                )
                state = .ready(documentCount: try await database.documentCount())
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
