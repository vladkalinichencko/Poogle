import SwiftUI

struct SearchResultRow: View {
    let result: SearchResult
    let open: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text(result.title.isEmpty ? fileName : result.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: reveal) {
                        Image(systemName: "finder")
                            .font(.caption)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Show in Finder")
                }

                if !result.section.isEmpty, result.section != "Body" {
                    Text(result.section)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !cleanSnippet.isEmpty {
                    Text(cleanSnippet)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture {
                open()
            }

            Text(relevanceText)
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("Relevance to the query")
        }
        .padding(.vertical, 20)
    }

    private var relevanceText: String {
        let percent = Int((result.score * 100).rounded())
        return "\(max(0, min(percent, 100)))%"
    }

    private var cleanSnippet: String {
        let words = result.snippet
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        var start = 0
        while start < words.count {
            let prefix = words[start]
            let authorLike = prefix.contains(",")
                || prefix.range(
                    of: #"^[A-Z]\.?$"#,
                    options: .regularExpression
                ) != nil
            let numericLike = prefix.range(
                of: #"^\(?\d+[\d.,:;()\-]*$"#,
                options: .regularExpression
            ) != nil
            if authorLike || numericLike {
                start += 1
            } else {
                break
            }
        }
        let trimmed = words.dropFirst(start).joined(separator: " ")
        if trimmed.count >= 24 {
            return trimmed
        }
        return result.snippet
    }

    private var fileName: String {
        URL(filePath: result.path).deletingPathExtension().lastPathComponent
    }
}
