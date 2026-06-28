import SwiftUI

struct ContentView: View {
    let store: LibraryStore

    private let contentWidth: CGFloat = 840
    private let horizontalPadding: CGFloat = 104

    var body: some View {
        Group {
            if shouldScroll {
                ScrollView {
                    content
                        .padding(.vertical, 64)
                }
                .poogleScrollEdgeEffect()
            } else {
                // Bias the resting position upward: top gap 0.4, bottom gap 0.6.
                // Adjacent spacers each take an equal share of the free space, so
                // two above and three below split it 2:3.
                VStack(spacing: 0) {
                    Spacer(minLength: 44)
                    Spacer(minLength: 0)
                    content
                    Spacer(minLength: 44)
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }

    private var shouldScroll: Bool {
        store.searchState == .results
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            SearchBar(store: store)

            IndexControls(store: store)

            statusLine

            resultList
        }
        .frame(maxWidth: contentWidth, alignment: .leading)
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Poogle")
                .font(.system(size: 76, weight: .bold))
            Text("Search publications on your Mac")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var statusLine: some View {
        Group {
            switch store.searchState {
            case .searching:
                SearchingStatus(progress: store.searchProgress)
            case .results:
                Text("\(store.results.count) most relevant papers")
            case .noResults:
                Text("No results for “\(store.query)”")
            case let .failed(message):
                Text(message)
                    .foregroundStyle(.red)
            default:
                indexStatusLine
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var resultList: some View {
        switch store.searchState {
        case .results:
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.results.enumerated()), id: \.element.id) {
                    offset,
                    result in
                    SearchResultRow(
                        result: result,
                        open: { store.open(result) },
                        reveal: { store.reveal(result) }
                    )

                    if offset < store.results.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.top, 8)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var indexStatusLine: some View {
        switch store.state {
        case .empty:
            Text("Choose a folder, then synchronize its PDF files.")
        case .scanning, .preparing, .indexing, .stopping:
            EmptyView()
        case let .ready(documentCount):
            if !store.skippedFiles.isEmpty {
                Text(
                    "\(store.skippedFiles.count) unreadable PDF files skipped; \(documentCount) indexed."
                )
            }
        case let .failed(message):
            Text(message)
                .foregroundStyle(.red)
            }
    }
}

private struct SearchingStatus: View {
    let progress: SearchProgress?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .monospacedDigit()
        }
    }

    private var label: String {
        switch progress {
        case .embedding, .none:
            "Reading your query…"
        case .retrieving:
            "Finding candidate papers…"
        case let .ranking(done, _):
            "Ranking by relevance — \(done)"
        }
    }
}

private extension View {
    @ViewBuilder
    func poogleScrollEdgeEffect() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}
