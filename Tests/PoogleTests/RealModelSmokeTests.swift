import Foundation
import Testing
@testable import Poogle

@Test
func realModelsIndexAndSearchOnePaper() async throws {
    guard let path = ProcessInfo.processInfo.environment["POOGLE_REAL_PDF"] else {
        return
    }
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let url = URL(filePath: path)
    let values = try url.resourceValues(
        forKeys: [.contentModificationDateKey, .fileSizeKey]
    )
    let fingerprint = FileFingerprint(
        documentID: "real-model-paper",
        path: path,
        modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
        byteCount: Int64(values.fileSize ?? 0)
    )
    let worker = EmbeddingWorker()
    let database = try IndexDatabase(
        url: directory.appending(path: "index.sqlite")
    )
    let embedded = try worker.embed(url)
    try await database.replace(embedded, fingerprint: fingerprint)
    let results = try await SearchEngine(
        database: database,
        worker: worker
    ).search("dynamical systems and non-Euclidean geometry")

    #expect(embedded.chunks.allSatisfy { $0.embedding.count == 256 })
    #expect(embedded.document.sections.allSatisfy { !$0.text.contains("\n") })
    #expect(embedded.chunks.count < 100)
    #expect(results.first?.path == path)
}
