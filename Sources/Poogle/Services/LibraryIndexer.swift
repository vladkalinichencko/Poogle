import Foundation

struct LibrarySyncResult: Sendable {
    let scannedCount: Int
    let indexedCount: Int
    let documentCount: Int
    let skippedFiles: [String]
}

struct LibraryIndexer: Sendable {
    let scanner: DocumentScanner
    let worker: EmbeddingWorker
    let database: IndexDatabase

    func sync(
        folder: URL,
        rebuild: Bool = false,
        onState: @Sendable (IndexState) async -> Void = { _ in },
        onSkipped: @Sendable (String) async -> Void = { _ in }
    ) async throws -> LibrarySyncResult {
        await onState(.scanning)
        if rebuild {
            try await database.rebuild()
        }

        let files = try await Task.detached {
            try scanner.fingerprints(in: folder)
        }.value
        try Task.checkCancellation()
        let uniqueFiles = scanner.uniqueDocuments(in: files)
        await onState(.preparing(total: uniqueFiles.count))
        let pendingPaths = try await database.prepareSync(files)
        let pending = scanner.uniqueDocuments(in: pendingPaths)
        var skippedFiles: [String] = []

        for (offset, fingerprint) in pending.enumerated() {
            try Task.checkCancellation()
            let fileName = URL(filePath: fingerprint.path).lastPathComponent
            await onState(
                .indexing(
                    completed: offset,
                    total: pending.count,
                    fileName: fileName
                )
            )
            do {
                let embedded = try await Task.detached {
                    try worker.embed(URL(filePath: fingerprint.path))
                }.value
                try Task.checkCancellation()
                try await database.replace(
                    embedded,
                    fingerprint: fingerprint
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skippedFiles.append(fileName)
                await onSkipped(fileName)
                worker.stop()
            }
        }

        _ = try await database.prepareSync(files)
        try await database.removeMissing(paths: Set(files.map(\.path)))
        let documentCount = try await database.documentCount()
        await onState(.ready(documentCount: documentCount))
        return LibrarySyncResult(
            scannedCount: uniqueFiles.count,
            indexedCount: pending.count - skippedFiles.count,
            documentCount: documentCount,
            skippedFiles: skippedFiles
        )
    }
}

enum LibrarySettings {
    static var folder: URL? {
        guard let path = UserDefaults.standard.string(
            forKey: "libraryFolder"
        ) else {
            return nil
        }
        return URL(filePath: path)
    }

    static func save(folder: URL?) {
        UserDefaults.standard.set(folder?.path, forKey: "libraryFolder")
    }
}
