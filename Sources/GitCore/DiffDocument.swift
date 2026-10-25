import Foundation

public struct DiffLine: Identifiable, Sendable {
    public let id: Int
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
    public let kind: Kind
    public enum Kind: Sendable { case addition, deletion, hunk, context, metadata }
}

public struct DiffDocument: Sendable {
    public let lines: [DiffLine]
    public let isTruncated: Bool
    public init(_ text: String, limit: Int = 8000) {
        var old: Int?; var new: Int?
        var result: [DiffLine] = []
        let records = text.components(separatedBy: "\n")
        isTruncated = records.count > limit
        for (index, line) in records.prefix(limit).enumerated() {
            var kind: DiffLine.Kind = .metadata
            var oldNumber: Int?; var newNumber: Int?
            if line.hasPrefix("@@ ") {
                let ranges = line.split(separator: " ")
                if ranges.count >= 3 {
                    old = Int(ranges[1].dropFirst().split(separator: ",")[0])
                    new = Int(ranges[2].dropFirst().split(separator: ",")[0])
                }
                kind = .hunk
            } else if line.hasPrefix("diff --git ") {
                old = nil; new = nil
            } else if old != nil && new != nil {
                if line.hasPrefix("+") {
                    kind = .addition; newNumber = new; new = new.map { $0 + 1 }
                } else if line.hasPrefix("-") {
                    kind = .deletion; oldNumber = old; old = old.map { $0 + 1 }
                } else if line.hasPrefix(" ") {
                    kind = .context; oldNumber = old; newNumber = new
                    old = old.map { $0 + 1 }; new = new.map { $0 + 1 }
                }
            }
            result.append(DiffLine(id: index, text: String(line), oldNumber: oldNumber, newNumber: newNumber, kind: kind))
        }
        lines = result
    }
}
