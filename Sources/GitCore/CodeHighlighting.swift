import Foundation
import Darwin

public struct CodeSpan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case keyword, string, comment, number }
    public let range: NSRange
    public let kind: Kind
}

public struct DiffCodeLine: Sendable, Equatable {
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
        var fallback = ""
        var found = ""
        let handledContiguous = diff.utf8.withContiguousStorageIfAvailable { (buffer: UnsafeBufferPointer<UInt8>) -> Bool in
            guard let base = buffer.baseAddress else { return true }
            let total = buffer.count
            var offset = 0
            while offset < total {
                let remaining = total - offset
                let newline = memchr(base.advanced(by: offset), Int32(0x0A), remaining)
                let lineEnd = newline.map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? total
                let length = lineEnd - offset
                if length >= 6 && memcmp(base.advanced(by: offset), "+++ b/", 6) == 0 {
                    found = String(decoding: UnsafeBufferPointer(start: base.advanced(by: offset + 6), count: length - 6), as: UTF8.self)
                    return true
                }
                if fallback.isEmpty && length >= 6 && memcmp(base.advanced(by: offset), "--- a/", 6) == 0 {
                    fallback = String(decoding: UnsafeBufferPointer(start: base.advanced(by: offset + 6), count: length - 6), as: UTF8.self)
                }
                if length >= 3 && memcmp(base.advanced(by: offset), "@@ ", 3) == 0 {
                    break
                }
                if newline == nil { break }
                offset = lineEnd + 1
            }
            return true
        } ?? false

        if handledContiguous { return found.isEmpty ? fallback : found }

        var start = diff.startIndex
        while start < diff.endIndex {
            let end = diff[start...].firstIndex(of: "\n") ?? diff.endIndex
            let line = diff[start..<end]
            if line.hasPrefix("+++ b/") { return String(line.dropFirst(6)) }
            if fallback.isEmpty && line.hasPrefix("--- a/") { fallback = String(line.dropFirst(6)) }
            if line.hasPrefix("@@ ") { break }
            if end == diff.endIndex { break }
            start = diff.index(after: end)
        }
        return fallback
    }
    private static let extensions: Set<String> = ["swift", "m", "mm", "h", "c", "cpp", "hpp", "cs", "java", "kt", "kts", "js", "jsx", "ts", "tsx", "json", "py", "rb", "rs", "go", "sh", "bash", "zsh", "yml", "yaml", "toml", "sql"]
    private static let keywords: Set<String> = Set("actor async await break case catch class const continue default defer deinit do else enum export extension false fileprivate final for from func function guard if import in init inout internal is let match mut namespace new nil nonisolated null open operator override package private protocol public repeat required return self Self some static struct super switch this throw throws trait true try type typealias typeof undefined var void where while with yield def elif except lambda None True False fn impl pub use mod select SELECT FROM WHERE INSERT UPDATE DELETE".split(separator: " ").map(String.init))
    private static let minKeywordLength = keywords.map(\.utf16.count).min() ?? 2
    private static let maxKeywordLength = keywords.map(\.utf16.count).max() ?? 16
    private static let hashCommentExtensions: Set<String> = ["py", "rb", "sh", "bash", "zsh", "yml", "yaml", "toml"]

    @inline(__always)
    private static func isASCIIWord(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
    }

    @inline(__always)
    private static func isASCIIIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
    }

    @inline(__always)
    private static func isWordUnit(_ units: [UInt16], at index: Int) -> Bool {
        guard index >= 0 && index < units.count else { return false }
        let unit = units[index]
        if unit < 128 { return isASCIIWord(unit) }
        if let scalar = UnicodeScalar(unit) { return CharacterSet.alphanumerics.contains(scalar) }
        return false
    }

    public static func spans(_ source: String, path: String) -> [CodeSpan] {
        let ext = (path as NSString).pathExtension.lowercased()
        guard extensions.contains(ext), source.utf16.count <= 16_384 else { return [] }
        let units = Array(source.utf16)
        let count = units.count
        guard count > 0 else { return [] }
        var spans: [CodeSpan] = []
        let hashComments = hashCommentExtensions.contains(ext)
        var index = 0
        while index < count {
            let unit = units[index]
            if hashComments && unit == 35 {
                spans.append(CodeSpan(range: NSRange(location: index, length: count - index), kind: .comment))
                break
            }
            if unit == 47 && index + 1 < count {
                let next = units[index + 1]
                if next == 47 {
                    var end = index + 2
                    while end < count && units[end] != 10 { end += 1 }
                    spans.append(CodeSpan(range: NSRange(location: index, length: end - index), kind: .comment))
                    index = end
                    continue
                }
                if next == 42 {
                    var cursor = index + 2
                    var closed = -1
                    while cursor + 1 < count {
                        if units[cursor] == 42 && units[cursor + 1] == 47 {
                            closed = cursor + 2
                            break
                        }
                        cursor += 1
                    }
                    if closed > 0 {
                        spans.append(CodeSpan(range: NSRange(location: index, length: closed - index), kind: .comment))
                        index = closed
                        continue
                    }
                }
            }
            if unit == 34 || unit == 39 {
                var cursor = index + 1
                var closed = -1
                while cursor < count {
                    let current = units[cursor]
                    if current == 92 {
                        if cursor + 1 < count { cursor += 2; continue }
                        break
                    }
                    if current == unit {
                        closed = cursor + 1
                        break
                    }
                    cursor += 1
                }
                if closed > 0 {
                    spans.append(CodeSpan(range: NSRange(location: index, length: closed - index), kind: .string))
                    index = closed
                    continue
                }
            }
            if unit >= 48 && unit <= 57 && !isWordUnit(units, at: index - 1) {
                var end = index + 1
                while end < count && units[end] >= 48 && units[end] <= 57 { end += 1 }
                if end + 1 < count && units[end] == 46 && units[end + 1] >= 48 && units[end + 1] <= 57 {
                    end += 2
                    while end < count && units[end] >= 48 && units[end] <= 57 { end += 1 }
                }
                if !isWordUnit(units, at: end) {
                    spans.append(CodeSpan(range: NSRange(location: index, length: end - index), kind: .number))
                    index = end
                    continue
                }
                while end < count && isWordUnit(units, at: end) { end += 1 }
                index = end
                continue
            }
            if isASCIIIdentifierStart(unit) && !isWordUnit(units, at: index - 1) {
                var end = index + 1
                while end < count && isASCIIWord(units[end]) { end += 1 }
                if !isWordUnit(units, at: end) {
                    let length = end - index
                    if length >= minKeywordLength && length <= maxKeywordLength {
                        let word = String(decoding: units[index..<end], as: UTF16.self)
                        if keywords.contains(word) {
                            spans.append(CodeSpan(range: NSRange(location: index, length: length), kind: .keyword))
                        }
                    }
                    index = end
                    continue
                }
                while end < count && isWordUnit(units, at: end) { end += 1 }
                index = end
                continue
            }
            index += 1
        }
        return spans
    }

    public static func prepare(_ lines: [DiffLine], path: String, alignedRows: [SplitDiffRow]? = nil) -> [Int: DiffCodeLine] {
        var result: [Int: DiffCodeLine] = [:]
        result.reserveCapacity(lines.count)
        for line in lines {
            result[line.id] = DiffCodeLine(source: source(line), path: path)
        }
        let rows = alignedRows ?? SplitDiffRow.align(lines)
        for row in rows {
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
        func tokens(_ text: String) -> [(Substring, NSRange)] {
            var result: [(Substring, NSRange)] = []
            let scalars = text.unicodeScalars
            var tokenStart = scalars.startIndex
            var tokenUTF16Start = 0
            var currentUTF16Offset = 0
            var previousWord: Bool?
            var cursor = scalars.startIndex
            while cursor < scalars.endIndex {
                let scalar = scalars[cursor]
                let value = scalar.value
                let word = value < 128
                    ? ((value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122) || value == 95)
                    : CharacterSet.alphanumerics.contains(scalar)
                if let previousWord, word != previousWord || !word {
                    result.append((text[tokenStart..<cursor], NSRange(location: tokenUTF16Start, length: currentUTF16Offset - tokenUTF16Start)))
                    tokenStart = cursor
                    tokenUTF16Start = currentUTF16Offset
                }
                previousWord = word
                currentUTF16Offset += scalar.utf16.count
                scalars.formIndex(after: &cursor)
            }
            if tokenStart < scalars.endIndex {
                result.append((text[tokenStart..<scalars.endIndex], NSRange(location: tokenUTF16Start, length: currentUTF16Offset - tokenUTF16Start)))
            }
            return result
        }
        if old.utf16.count <= 4096, new.utf16.count <= 4096 {
            let lhs = tokens(old), rhs = tokens(new)
            var prefixCount = 0
            let sharedMin = min(lhs.count, rhs.count)
            while prefixCount < sharedMin && lhs[prefixCount].0 == rhs[prefixCount].0 { prefixCount += 1 }
            var suffixCount = 0
            let remainingMin = sharedMin - prefixCount
            while suffixCount < remainingMin && lhs[lhs.count - 1 - suffixCount].0 == rhs[rhs.count - 1 - suffixCount].0 { suffixCount += 1 }
            let lhsMid = lhs[prefixCount..<(lhs.count - suffixCount)]
            let rhsMid = rhs[prefixCount..<(rhs.count - suffixCount)]
            if lhsMid.count * rhsMid.count <= 65_536 {
                var removed: [NSRange] = [], inserted: [NSRange] = []
                let lhsWords = lhsMid.map(\.0)
                let rhsWords = rhsMid.map(\.0)
                for change in rhsWords.difference(from: lhsWords) {
                    switch change {
                    case .remove(let index, _, _): removed.append(lhs[prefixCount + index].1)
                    case .insert(let index, _, _): inserted.append(rhs[prefixCount + index].1)
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
