import Foundation
import Testing
@testable import Poogle

@Test
func scannerRecursesAndReturnsOnlyRegularPDFs() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    let nested = root.appending(path: "one/two")
    try FileManager.default.createDirectory(
        at: nested,
        withIntermediateDirectories: true
    )
    let pdf = nested.appending(path: "paper.PDF")
    try Data("pdf".utf8).write(to: pdf)
    let alias = nested.appending(path: "paper alias.pdf")
    let bookmark = try pdf.bookmarkData(
        options: .suitableForBookmarkFile,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
    try URL.writeBookmarkData(bookmark, to: alias)
    try Data("html".utf8).write(to: root.appending(path: "page.html"))
    try Data("mhtml".utf8).write(to: nested.appending(path: "page.mhtml"))
    try Data("archive".utf8).write(to: nested.appending(path: "page.webarchive"))

    let files = try DocumentScanner().fingerprints(in: root)

    #expect(
        files.map { URL(filePath: $0.path).standardizedFileURL.path }
            == [pdf.standardizedFileURL.path]
    )
}

@Test
func scannerCountsIdenticalFilesAsOneDocument() {
    let fingerprints = [
        FileFingerprint(
            documentID: "same-hash",
            path: "/papers/first.pdf",
            modifiedAt: 1,
            byteCount: 2
        ),
        FileFingerprint(
            documentID: "same-hash",
            path: "/papers/second.pdf",
            modifiedAt: 1,
            byteCount: 2
        ),
        FileFingerprint(
            documentID: "other-hash",
            path: "/papers/third.pdf",
            modifiedAt: 1,
            byteCount: 3
        ),
    ]

    let unique = DocumentScanner().uniqueDocuments(in: fingerprints)

    #expect(unique.map(\.path) == [
        "/papers/first.pdf",
        "/papers/third.pdf",
    ])
}
