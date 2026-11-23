import Foundation
import Darwin

public struct DiffLine: Identifiable, Sendable, Equatable {
    public let id: Int
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
    public let kind: Kind
    public enum Kind: Sendable, Equatable { case addition, deletion, hunk, context, metadata }
}

public struct DiffDocument: Sendable {
    public let lines: [DiffLine]
    public let isTruncated: Bool
    public init(_ text: String, limit: Int = 8000) {
        guard limit > 0 else {
            lines = []
            isTruncated = true
            return
        }
        var oldNumberCursor: Int?
        var newNumberCursor: Int?
        var result: [DiffLine] = []
        result.reserveCapacity(min(limit, 1024))
        var truncated = false
        var index = 0

        func appendLine(_ line: String) {
            var kind: DiffLine.Kind = .metadata
            var oldNumber: Int?
            var newNumber: Int?
            if line.hasPrefix("@@ ") {
                if let parsed = Self.parseHunkStarts(line) {
                    oldNumberCursor = parsed.0
                    newNumberCursor = parsed.1
                }
                kind = .hunk
            } else if line.hasPrefix("diff --git ") {
                oldNumberCursor = nil
                newNumberCursor = nil
            } else if oldNumberCursor != nil && newNumberCursor != nil {
                if line.hasPrefix("+") {
                    kind = .addition
                    newNumber = newNumberCursor
                    newNumberCursor = newNumberCursor.map { $0 + 1 }
                } else if line.hasPrefix("-") {
                    kind = .deletion
                    oldNumber = oldNumberCursor
                    oldNumberCursor = oldNumberCursor.map { $0 + 1 }
                } else if line.hasPrefix(" ") {
                    kind = .context
                    oldNumber = oldNumberCursor
                    newNumber = newNumberCursor
                    oldNumberCursor = oldNumberCursor.map { $0 + 1 }
                    newNumberCursor = newNumberCursor.map { $0 + 1 }
                }
            }
            result.append(DiffLine(id: index, text: line, oldNumber: oldNumber, newNumber: newNumber, kind: kind))
            index += 1
        }

        let handledContiguous = text.utf8.withContiguousStorageIfAvailable { (buffer: UnsafeBufferPointer<UInt8>) -> Bool in
            guard let base = buffer.baseAddress else {
                appendLine("")
                return true
            }
            let total = buffer.count
            var offset = 0
            while true {
                let remaining = total - offset
                let found = remaining > 0 ? memchr(base.advanced(by: offset), Int32(0x0A), remaining) : nil
                let lineEnd = found.map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? total
                appendLine(String(decoding: UnsafeBufferPointer(start: base.advanced(by: offset), count: lineEnd - offset), as: UTF8.self))
                if found == nil { break }
                if index == limit {
                    truncated = true
                    break
                }
                offset = lineEnd + 1
            }
            return true
        } ?? false

        if !handledContiguous {
            let utf8 = text.utf8
            var lineStart = utf8.startIndex
            while true {
                let newline = utf8[lineStart...].firstIndex(of: 0x0A)
                let lineEnd = newline ?? utf8.endIndex
                appendLine(String(decoding: utf8[lineStart..<lineEnd], as: UTF8.self))
                guard let newline else { break }
                if index == limit {
                    truncated = true
                    break
                }
                lineStart = utf8.index(after: newline)
            }
        }

        isTruncated = truncated
        lines = result
    }

    private static func parseHunkStarts(_ line: String) -> (Int?, Int?)? {
        let ranges = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard ranges.count >= 3 else { return nil }
        let oldToken = ranges[1].dropFirst()
        let newToken = ranges[2].dropFirst()
        let oldEnd = oldToken.firstIndex(of: ",") ?? oldToken.endIndex
        let newEnd = newToken.firstIndex(of: ",") ?? newToken.endIndex
        return (Int(oldToken[..<oldEnd]), Int(newToken[..<newEnd]))
    }
}
