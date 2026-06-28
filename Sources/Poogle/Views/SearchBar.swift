import SwiftUI

struct SearchBar: View {
    let store: LibraryStore

    var body: some View {
        let height: CGFloat = 60
        let buttonDiameter: CGFloat = 32
        let edgeInset = (height - buttonDiameter) / 2 - 4

        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            TextField(
                "Search publications, methods, concepts, or authors",
                text: Bindable(store).query
            )
            .textFieldStyle(.plain)
            .font(.title3)
            .onSubmit {
                store.search()
            }

            if isShowingResults {
                Button {
                    store.clearSearch()
                } label: {
                    Image(systemName: "xmark")
                        .fontWeight(.semibold)
                        .frame(width: buttonDiameter, height: buttonDiameter)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
            } else {
                Button {
                    store.search()
                } label: {
                    Image(systemName: "arrow.right")
                        .fontWeight(.semibold)
                        .frame(width: buttonDiameter, height: buttonDiameter)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(store.query.trimmingCharacters(in: .whitespaces).isEmpty || !isReady)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, edgeInset)
        .frame(height: height)
        .poogleGlass(
            cornerRadius: height / 2,
            interactive: true
        )
    }

    private var isReady: Bool {
        if case .ready = store.state {
            true
        } else {
            false
        }
    }

    private var isShowingResults: Bool {
        switch store.searchState {
        case .searching, .results, .noResults, .failed:
            true
        default:
            false
        }
    }
}
