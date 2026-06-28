import CryptoKit
import Foundation

struct DocumentScanner: Sendable {
    func fingerprints(in folder: URL) throws -> [FileFingerprint] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isAliasFileKey,
            .isRegularFileKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        return enumerator.compactMap { element in
            guard let url = element as? URL,
                  url.pathExtension.lowercased() == "pdf" else {
                return nil
            }

            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isAliasFile != true,
                  let documentID = try? sha256(url) else {
                return nil
            }

            return FileFingerprint(
                documentID: documentID,
                path: url.path,
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                byteCount: Int64(values.fileSize ?? 0)
            )
        }
        .sorted { $0.path < $1.path }
    }

    func uniqueDocuments(
        in fingerprints: [FileFingerprint]
    ) -> [FileFingerprint] {
        var documentIDs: Set<String> = []
        return fingerprints.filter {
            documentIDs.insert($0.documentID).inserted
        }
    }

    private func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
