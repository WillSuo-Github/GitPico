import Foundation

public enum ConflictChoice: String, Sendable { case current, incoming, both, base }

public struct ConflictRegion: Identifiable, Sendable {
    public let id: Int
    public let current: String
    public let incoming: String
    public let base: String?
    public let original: String
}

public struct ConflictDocument: Sendable {
    public enum Segment: Sendable { case text(String), conflict(ConflictRegion) }
    public let segments: [Segment]
    public var regions: [ConflictRegion] { segments.compactMap { if case .conflict(let region) = $0 { region } else { nil } } }
    public let hasMarkers: Bool

    public init(_ text: String) {
        let parts = text.components(separatedBy: "\n")
        let lines = parts.enumerated().map { $0.element + ($0.offset < parts.count - 1 ? "\n" : "") }
        func marker(_ line: String, _ character: Character, count: Int? = nil) -> Bool {
            let prefix = line.prefix { $0 == character }.count
            guard prefix >= 7, count == nil || count == prefix else { return false }
            let suffix = line.dropFirst(prefix)
            return suffix.isEmpty || suffix.first?.isWhitespace == true
        }
        hasMarkers = lines.contains { marker($0, "<") || marker($0, "|") || marker($0, "=") || marker($0, ">") }
        var result: [Segment] = []; var plain = ""; var index = 0; var ordinal = 0
        while index < lines.count {
            guard marker(lines[index], "<") else { plain += lines[index]; index += 1; continue }
            let start = index
            let size = lines[start].prefix { $0 == "<" }.count
            var divider: Int?; var base: Int?; var end: Int?
            var cursor = start + 1
            while cursor < lines.count {
                if marker(lines[cursor], "<") { break }
                if marker(lines[cursor], "|", count: size), divider == nil { base = cursor }
                if marker(lines[cursor], "=", count: size), divider == nil { divider = cursor }
                if marker(lines[cursor], ">", count: size), divider != nil { end = cursor; break }
                cursor += 1
            }
            guard let divider, let end else { plain += lines[index]; index += 1; continue }
            if !plain.isEmpty { result.append(.text(plain)); plain = "" }
            let region = ConflictRegion(id: ordinal, current: lines[(start + 1)..<(base ?? divider)].joined(), incoming: lines[(divider + 1)..<end].joined(), base: base.map { lines[($0 + 1)..<divider].joined() }, original: lines[start...end].joined())
            result.append(.conflict(region)); ordinal += 1; index = end + 1
        }
        if !plain.isEmpty { result.append(.text(plain)) }
        segments = result
    }

    public func resolving(_ id: Int, with choice: ConflictChoice) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text): return text
            case .conflict(let region):
                guard region.id == id else { return region.original }
                switch choice {
                case .current: return region.current
                case .incoming: return region.incoming
                case .both: return region.current + region.incoming
                case .base: return region.base ?? region.original
                }
            }
        }.joined()
    }
}
