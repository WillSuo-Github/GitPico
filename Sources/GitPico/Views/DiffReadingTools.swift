import AppKit
import GitCore
import SwiftUI

struct DiffCodeText: View {
    let line: DiffCodeLine
    var query = ""
    var body: some View {
        Text(attributed).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
    }
    private var attributed: AttributedString {
        var value = AttributedString(line.source.isEmpty ? " " : line.source)
        func attributedRange(_ range: NSRange) -> Range<AttributedString.Index>? {
            guard let range = Range(range, in: line.source),
                  let lower = AttributedString.Index(range.lowerBound, within: value),
                  let upper = AttributedString.Index(range.upperBound, within: value) else { return nil }
            return lower..<upper
        }
        for span in line.syntax {
            guard let range = attributedRange(span.range) else { continue }
            value[range].foregroundColor = switch span.kind {
            case .keyword: SyntaxPalette.keyword
            case .string: SyntaxPalette.string
            case .comment: .secondary
            case .number: SyntaxPalette.number
            }
        }
        for span in line.changes {
            guard let range = attributedRange(span) else { continue }
            value[range].backgroundColor = Color.accentColor.opacity(0.22)
            value[range].inlinePresentationIntent = .stronglyEmphasized
        }
        for span in CodeHighlighting.matches(line.source, query: query) {
            guard let range = attributedRange(span) else { continue }
            value[range].backgroundColor = Color.yellow.opacity(0.45)
            value[range].foregroundColor = .primary
        }
        return value
    }
}

private enum SyntaxPalette {
    static let keyword = adaptive(light: (0.42, 0.16, 0.65), dark: (0.82, 0.64, 0.98))
    static let string = adaptive(light: (0.62, 0.20, 0.09), dark: (0.96, 0.73, 0.61))
    static let number = adaptive(light: (0.09, 0.34, 0.68), dark: (0.56, 0.75, 1.0))
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }
}

struct DiffFindBar: View {
    @Binding var query: String
    let matches: [String]
    @Binding var selection: String?
    var didNavigate: () -> Void = {}
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in Diff", text: $query).textFieldStyle(.plain).onSubmit { move(1) }
                .accessibilityLabel("Find in this diff")
            if !query.isEmpty {
                Text(matches.isEmpty ? String(localized: "No matches") : "\(matches.firstIndex(of: selection ?? "").map { $0 + 1 } ?? 0) / \(matches.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.help("Previous matching line").accessibilityLabel("Previous matching line")
                Button { move(1) } label: { Image(systemName: "chevron.down") }.help("Next matching line").accessibilityLabel("Next matching line")
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.help("Clear diff search").accessibilityLabel("Clear diff search")
            }
        }.buttonStyle(.borderless).font(.system(size: 12)).padding(.horizontal, 14).frame(height: 32)
            .background(.bar).overlay(alignment: .bottom) { Divider() }
            .onChange(of: query) { selection = matches.first; didNavigate() }
            .onChange(of: matches) { if !matches.contains(selection ?? "") { selection = matches.first; didNavigate() } }
    }
    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex(of: selection ?? "") ?? (delta > 0 ? -1 : 0)
        selection = matches[(current + delta + matches.count) % matches.count]
        didNavigate()
    }
}
