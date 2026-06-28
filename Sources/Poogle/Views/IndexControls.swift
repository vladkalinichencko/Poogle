import SwiftUI

struct IndexControls: View {
    let store: LibraryStore

    var body: some View {
        HStack(spacing: 14) {
            Button {
                store.chooseFolder()
            } label: {
                Label(folderLabel, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.folder == nil ? .secondary : .primary)
            .disabled(isIndexing)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(store.folder?.path(percentEncoded: false) ?? "Choose PDF folder")

            Spacer(minLength: 24)

            syncStatus

            Button {
                isIndexing ? store.stop() : store.index()
            } label: {
                Image(systemName: isIndexing ? "stop.fill" : "arrow.clockwise")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isIndexing ? .red : .secondary)
            .tint(isIndexing ? .red : nil)
            .disabled(store.folder == nil)
            .help(isIndexing ? "Stop indexing" : "Synchronize new and changed PDFs")
        }
        .font(.callout)
        .frame(height: 30)
    }

    private var folderLabel: String {
        store.folder?.lastPathComponent ?? "Choose Folder"
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch store.state {
        case .scanning:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning PDFs")
            }
            .foregroundStyle(.secondary)
        case let .preparing(total):
            Text("Checking \(total) PDFs")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case let .indexing(completed, total, _):
            HStack(spacing: 10) {
                ProgressView(
                    value: Double(completed),
                    total: Double(max(total, 1))
                )
                .frame(width: 130)
                Text("\(completed) / \(total)")
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
        case let .stopping(completed, total):
            ProgressView()
                .controlSize(.small)
            Text("\(completed) / \(total)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case let .ready(documentCount):
            Text("\(documentCount) PDFs")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .empty:
            Text("Not synchronized")
                .foregroundStyle(.secondary)
        case .failed:
            Text("Synchronization failed")
                .foregroundStyle(.red)
        }
    }

    private var isIndexing: Bool {
        switch store.state {
        case .scanning, .preparing, .indexing, .stopping:
            true
        default:
            false
        }
    }
}
