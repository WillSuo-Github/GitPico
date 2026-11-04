import Foundation

public struct CodeSpan: Sendable {
    public enum Kind: Sendable { case keyword, string, comment, number }
    public let range: NSRange
    public let kind: Kind
}

public struct DiffCodeLine: Sendable {
    public let source: String
    public var syntax: [CodeSpan]
    public var changes: [NSRange] = []
    public init(source: String, path: String) {
        self.source = source
        syntax = CodeHighlighting.spans(source, path: path)
    }
}

/// Bounded lexical highlighting. All ranges are UTF-16 offsets for attributed text.
public enum CodeHighlighting {
    public static func source(_ line: DiffLine) -> String {
        [.addition, .deletion, .context].contains(line.kind) ? String(line.text.dropFirst()) : line.text
    }
    public static func path(in diff: String) -> String {
        let lines = diff.split(separator: "\n")
        if let line = lines.first(where: { $0.hasPrefix("+++ b/") }) { return String(line.dropFirst(6)) }
        if let line = lines.first(where: { $0.hasPrefix("--- a/") }) { return String(line.dropFirst(6)) }
        return ""
    }
    private static let extensions: Set<String> = ["swift", "m", "mm", "h", "c", "cpp", "hpp", "cs", "java", "kt", "kts", "js", "jsx", "ts", "tsx", "json", "py", "rb", "rs", "go", "sh", "bash", "zsh", "yml", "yaml", "toml", "sql"]
    private static let keywords: Set<String> = Set("actor async await break case catch class const continue default defer deinit do else enum export extension false fileprivate final for from func function guard if import in init inout internal is let match mut namespace new nil nonisolated null open operator override package private protocol public repeat required return self Self some static struct super switch this throw throws trait true try type typealias typeof undefined var void where while with yield def elif except lambda None True False fn impl pub use mod select SELECT FROM WHERE INSERT UPDATE DELETE".split(separator: " ").map(String.init))
    private static let lexer = try! NSRegularExpression(pattern: #"(//[^\n]*|/\*.*?\*/)|("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(\b[0-9]+(?:\.[0-9]+)?\b)|(\b[A-Za-z_][A-Za-z_0-9]*\b)"#, options: [.dotMatchesLineSeparators])
    public static func spans(_ source: String, path: String) -> [CodeSpan] {
        let ext = (path as NSString).pathExtension.lowercased()
        guard extensions.contains(ext), source.utf16.count <= 16_384 else { return [] }
        let value = source as NSString
        var spans: [CodeSpan] = []
        // Hash comments are meaningful in these languages, but not Swift's # directives.
        let hashComments = ["py", "rb", "sh", "bash", "zsh", "yml", "yaml", "toml"].contains(ext)
        for match in lexer.matches(in: source, range: NSRange(location: 0, length: value.length)) {
            let kind: CodeSpan.Kind?
            if match.range(at: 1).location != NSNotFound { kind = .comment }
            else if match.range(at: 2).location != NSNotFound { kind = .string }
            else if match.range(at: 3).location != NSNotFound { kind = .number }
            else { kind = keywords.contains(value.substring(with: match.range)) ? .keyword : nil }
            if let kind { spans.append(CodeSpan(range: match.range, kind: kind)) }
        }
        if hashComments {
            // Ignore hash characters inside a quoted string.
            for (index, unit) in source.utf16.enumerated() where unit == 35 {
                if spans.contains(where: { NSLocationInRange(index, $0.range) && ($0.kind == .string || $0.kind == .comment) }) { continue }
                spans.removeAll { $0.range.location >= index }
                spans.append(CodeSpan(range: NSRange(location: index, length: value.length - index), kind: .comment))
                break
            }
        }
        return spans
    }

    public static func prepare(_ lines: [DiffLine], path: String) -> [Int: DiffCodeLine] {
        var result: [Int: DiffCodeLine] = [:]
        for line in lines {
            result[line.id] = DiffCodeLine(source: source(line), path: path)
        }
        for row in SplitDiffRow.align(lines) {
            guard let left = row.left, let right = row.right, left.kind == .deletion, right.kind == .addition,
                  let old = result[left.id]?.source, let new = result[right.id]?.source else { continue }
            let changes = changedRanges(old, new)
            result[left.id]?.changes = changes.0
            result[right.id]?.changes = changes.1
        }
        return result
    }

    public static func changedRanges(_ old: String, _ new: String) -> ([NSRange], [NSRange]) {
        guard old != new else { return ([], []) }
        // Token differences retain multiple independent changes on a line. Fall back
        // to one bounded span for generated/minified lines instead of quadratic work.
        func tokens(_ text: String) -> [(String, NSRange)] {
            var result: [(String, NSRange)] = [], start = 0, current = "", previousWord: Bool?
            for scalar in text.unicodeScalars {
                let word = CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
                if !current.isEmpty, word != previousWord || !word {
                    result.append((current, NSRange(location: start, length: current.utf16.count)))
                    start += current.utf16.count; current = ""
                }
                current.unicodeScalars.append(scalar); previousWord = word
            }
            if !current.isEmpty { result.append((current, NSRange(location: start, length: current.utf16.count))) }
            return result
        }
        if old.utf16.count <= 4096, new.utf16.count <= 4096 {
            let lhs = tokens(old), rhs = tokens(new)
            if lhs.count * rhs.count <= 65_536 {
                var removed: [NSRange] = [], inserted: [NSRange] = []
                for change in rhs.map(\.0).difference(from: lhs.map(\.0)) {
                    switch change {
                    case .remove(let index, _, _): removed.append(lhs[index].1)
                    case .insert(let index, _, _): inserted.append(rhs[index].1)
                    }
                }
                return (removed, inserted)
            }
        }
        var a = old.startIndex, b = new.startIndex
        while a != old.endIndex, b != new.endIndex, old[a] == new[b] {
            old.formIndex(after: &a); new.formIndex(after: &b)
        }
        var endA = old.endIndex, endB = new.endIndex
        while endA != a, endB != b {
            let previousA = old.index(before: endA), previousB = new.index(before: endB)
            guard old[previousA] == new[previousB] else { break }
            endA = previousA; endB = previousB
        }
        return (a == endA ? [] : [NSRange(a..<endA, in: old)], b == endB ? [] : [NSRange(b..<endB, in: new)])
    }

    public static func matches(_ text: String, query: String) -> [NSRange] {
        guard !query.isEmpty, query.utf16.count <= 4096 else { return [] }
        let value = text as NSString
        var range = NSRange(location: 0, length: value.length), result: [NSRange] = []
        while range.length > 0 && result.count < 1024 {
            let match = value.range(of: query, options: [.caseInsensitive], range: range)
            guard match.location != NSNotFound, match.length > 0 else { break }
            result.append(match)
            range = NSRange(location: NSMaxRange(match), length: value.length - NSMaxRange(match))
        }
        return result
    }
    public static func contains(_ text: String, query: String) -> Bool {
        !query.isEmpty && query.utf16.count <= 4096 && text.range(of: query, options: .caseInsensitive) != nil
    }
}
