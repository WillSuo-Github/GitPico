import AppKit
import GitCore
import SwiftUI

struct DiffCodeText: View, Equatable {
    nonisolated static let maxDisplayedUTF16Units = 1_024

    let line: DiffCodeLine
    var query = ""

    var body: some View {
        Text(attributed).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
    }

    nonisolated static func displayedColumnWidth(of source: String) -> Int {
        let utf16Count = source.utf16.count
        guard utf16Count > 0 else { return 1 }
        var columns = 0
        var units = 0
        for scalar in source.unicodeScalars {
            let scalarUnits = scalar.utf16.count
            if units + scalarUnits > maxDisplayedUTF16Units {
                return columns + 26
            }
            units += scalarUnits
            columns += scalar.value < 0x80 ? 1 : 2
        }
        return max(1, columns)
    }

    private static func displayedSlice(of source: String) -> (text: String, utf16Limit: Int, omittedCharacters: Int) {
        let totalUTF16 = source.utf16.count
        guard totalUTF16 > maxDisplayedUTF16Units else { return (source, totalUTF16, 0) }
        let utf16 = source.utf16
        let rawCut = utf16.index(utf16.startIndex, offsetBy: maxDisplayedUTF16Units)
        let safeCut = source.index(at: rawCut)
        let prefix = String(source[..<safeCut])
        let omitted = max(1, source[safeCut...].count)
        return (prefix, prefix.utf16.count, omitted)
    }

    private var attributed: AttributedString {
        if line.source.isEmpty { return AttributedString(" ") }
        let slice = Self.displayedSlice(of: line.source)
        let displayText = slice.text
        let utf16Limit = slice.utf16Limit
        let searchMatches = query.isEmpty ? [] : CodeHighlighting.matches(displayText, query: query)

        if line.syntax.isEmpty && line.changes.isEmpty && searchMatches.isEmpty && slice.omittedCharacters == 0 {
            return AttributedString(displayText)
        }

        var value = AttributedString(displayText)
        let utf16View = displayText.utf16

        func applySorted<T>(_ items: [T], range: (T) -> NSRange, apply: (inout AttributedSubstring, T) -> Void) {
            var cursorOffset = 0
            var cursorIndex = utf16View.startIndex
            for item in items {
                let raw = range(item)
                guard raw.location < utf16Limit else { break }
                let clampedEnd = min(utf16Limit, NSMaxRange(raw))
                guard clampedEnd > raw.location else { continue }
                let startIndex: String.Index
                if raw.location >= cursorOffset {
                    startIndex = utf16View.index(cursorIndex, offsetBy: raw.location - cursorOffset)
                } else {
                    startIndex = utf16View.index(utf16View.startIndex, offsetBy: raw.location)
                }
                let endIndex = utf16View.index(startIndex, offsetBy: clampedEnd - raw.location)
                cursorIndex = endIndex
                cursorOffset = clampedEnd
                guard let lower = AttributedString.Index(startIndex, within: value),
                      let upper = AttributedString.Index(endIndex, within: value),
                      lower < upper else { continue }
                apply(&value[lower..<upper], item)
            }
        }

        if !line.syntax.isEmpty {
            applySorted(line.syntax, range: \.range) { segment, span in
                segment.foregroundColor = switch span.kind {
                case .keyword: SyntaxPalette.keyword
                case .string: SyntaxPalette.string
                case .comment: .secondary
                case .number: SyntaxPalette.number
                }
            }
        }
        if !line.changes.isEmpty {
            applySorted(line.changes, range: { $0 }) { segment, _ in
                segment.backgroundColor = Color.accentColor.opacity(0.22)
                segment.inlinePresentationIntent = .stronglyEmphasized
            }
        }
        if !searchMatches.isEmpty {
            applySorted(searchMatches, range: { $0 }) { segment, _ in
                segment.backgroundColor = Color.yellow.opacity(0.45)
                segment.foregroundColor = .primary
            }
        }
        if slice.omittedCharacters > 0 {
            var suffix = AttributedString(" … (\(slice.omittedCharacters) chars omitted)")
            suffix.foregroundColor = .secondary
            value.append(suffix)
        }
        return value
    }
}

private extension String {
    func index(at utf16Index: UTF16View.Index) -> String.Index {
        if let aligned = utf16Index.samePosition(in: self) { return aligned }
        var cursor = utf16Index
        while cursor > utf16.startIndex {
            cursor = utf16.index(before: cursor)
            if let aligned = cursor.samePosition(in: self) { return aligned }
        }
        return startIndex
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
