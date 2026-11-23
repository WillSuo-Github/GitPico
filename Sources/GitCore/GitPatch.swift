import Foundation
import Darwin

public struct PatchHunk: Identifiable, Sendable {
    public let id: Int
    public let header: String
    public let text: String
    private let patchPrefix: String
    public var patch: String { patchPrefix + text + "\n" }

    init(id: Int, header: String, text: String, patchPrefix: String) {
        self.id = id
        self.header = header
        self.text = text
        self.patchPrefix = patchPrefix
    }
}

public struct PatchHunkPreview: Identifiable, Sendable {
    public var id: Int { hunk.id }
    public let hunk: PatchHunk
    public let lines: [DiffLine]
    public let isTruncated: Bool
}

public struct PatchDocument: Sendable {
    public let hunks: [PatchHunk]
    public let additions: Int
    public let deletions: Int
    public let supportsChunkStaging: Bool
    public let isBinary: Bool

    public init(_ text: String) {
        guard !text.isEmpty else {
            hunks = []
            additions = 0
            deletions = 0
            supportsChunkStaging = false
            isBinary = false
            return
        }

        var parsedHunks: [PatchHunk] = []
        var added = 0
        var removed = 0
        var structural = false
        var deletion = false
        var binaryHeader = false
        var diffHeaderCount = 0

        let handledContiguous = text.utf8.withContiguousStorageIfAvailable { (buffer: UnsafeBufferPointer<UInt8>) -> Bool in
            guard let base = buffer.baseAddress else { return true }
            let total = buffer.count
            let trimmedEnd = total > 0 && base[total - 1] == 0x0A ? total - 1 : total

            func hasPrefix(_ offset: Int, _ end: Int, _ prefix: StaticString) -> Bool {
                let length = prefix.utf8CodeUnitCount
                guard end - offset >= length else { return false }
                return memcmp(base.advanced(by: offset), prefix.utf8Start, length) == 0
            }

            var hunkStarts: [(start: Int, headerEnd: Int)] = []
            var hasHeader = false
            var headerEnd = 0
            var inHunk = false
            var offset = 0

            while true {
                let remaining = trimmedEnd - offset
                let found = remaining > 0 ? memchr(base.advanced(by: offset), Int32(0x0A), remaining) : nil
                let lineEnd = found.map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? trimmedEnd

                if hasPrefix(offset, lineEnd, "diff --git ") {
                    diffHeaderCount += 1
                    inHunk = false
                    if hunkStarts.isEmpty { hasHeader = true; headerEnd = lineEnd }
                } else if hasPrefix(offset, lineEnd, "@@ ") {
                    hunkStarts.append((offset, lineEnd))
                    inHunk = true
                } else {
                    if hunkStarts.isEmpty {
                        hasHeader = true
                        headerEnd = lineEnd
                        if !structural && (
                            hasPrefix(offset, lineEnd, "rename ") ||
                            hasPrefix(offset, lineEnd, "copy ") ||
                            hasPrefix(offset, lineEnd, "old mode") ||
                            hasPrefix(offset, lineEnd, "new mode")
                        ) {
                            structural = true
                        }
                        if !deletion && hasPrefix(offset, lineEnd, "deleted file mode") {
                            deletion = true
                        }
                        if !binaryHeader && (
                            hasPrefix(offset, lineEnd, "Binary files ") ||
                            hasPrefix(offset, lineEnd, "GIT binary patch")
                        ) {
                            binaryHeader = true
                        }
                    }
                    if inHunk && lineEnd > offset {
                        let firstByte = base[offset]
                        if firstByte == 0x2B { added += 1 }
                        else if firstByte == 0x2D { removed += 1 }
                    }
                }

                if found == nil { break }
                offset = lineEnd + 1
            }

            if !hunkStarts.isEmpty {
                let patchPrefix = hasHeader
                    ? String(decoding: UnsafeBufferPointer(start: base, count: headerEnd), as: UTF8.self) + "\n"
                    : ""
                parsedHunks.reserveCapacity(hunkStarts.count)
                for (index, item) in hunkStarts.enumerated() {
                    let hunkEnd = index + 1 < hunkStarts.count ? hunkStarts[index + 1].start - 1 : trimmedEnd
                    let headerLine = String(decoding: UnsafeBufferPointer(start: base.advanced(by: item.start), count: item.headerEnd - item.start), as: UTF8.self)
                    let hunkText = String(decoding: UnsafeBufferPointer(start: base.advanced(by: item.start), count: hunkEnd - item.start), as: UTF8.self)
                    parsedHunks.append(PatchHunk(id: index, header: headerLine, text: hunkText, patchPrefix: patchPrefix))
                }
            }
            return true
        } ?? false

        if !handledContiguous {
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            let starts = lines.indices.filter { lines[$0].hasPrefix("@@ ") }
            let header = Array(lines.prefix(starts.first ?? lines.count))
            let patchPrefix = header.isEmpty ? "" : header.joined(separator: "\n") + "\n"
            parsedHunks = starts.enumerated().map { offset, start in
                let end = offset + 1 < starts.count ? starts[offset + 1] : lines.count
                let hunkText = lines[start..<end].joined(separator: "\n")
                return PatchHunk(id: offset, header: lines[start], text: hunkText, patchPrefix: patchPrefix)
            }
            var inHunk = false
            for line in lines {
                if line.hasPrefix("diff --git ") { diffHeaderCount += 1; inHunk = false }
                else if line.hasPrefix("@@ ") { inHunk = true }
                else if inHunk && line.hasPrefix("+") { added += 1 }
                else if inHunk && line.hasPrefix("-") { removed += 1 }
            }
            structural = header.contains { $0.hasPrefix("rename ") || $0.hasPrefix("copy ") || $0.hasPrefix("old mode") || $0.hasPrefix("new mode") }
            deletion = header.contains { $0.hasPrefix("deleted file mode") }
            binaryHeader = header.contains { $0.hasPrefix("Binary files ") || $0.hasPrefix("GIT binary patch") }
        }

        hunks = parsedHunks
        additions = added
        deletions = removed
        isBinary = binaryHeader && parsedHunks.isEmpty
        supportsChunkStaging = !parsedHunks.isEmpty && !structural && !(deletion && parsedHunks.count > 1) && diffHeaderCount == 1
    }

    public func preview(limit: Int = 8000) -> [PatchHunkPreview] {
        var remaining = limit
        var result: [PatchHunkPreview] = []
        for hunk in hunks {
            guard remaining > 1 else { break }
            let document = DiffDocument(hunk.text, limit: remaining)
            remaining -= document.lines.count
            result.append(PatchHunkPreview(hunk: hunk, lines: Array(document.lines.dropFirst()), isTruncated: document.isTruncated))
        }
        return result
    }
}

extension GitRepository {
    public func stageChunk(_ change: FileChange, renderedDiff: String, hunkID: Int, reverse: Bool, context: Int = 7) async throws {
        guard !change.isConflicted else { throw GitFailure("Stage the whole resolved file to mark a conflict resolved.") }
        let current = try await diff(change, staged: reverse, context: context)
        guard current == renderedDiff else { throw GitFailure("The file changed since this diff was loaded. Refresh before staging a chunk.") }
        let document = PatchDocument(renderedDiff)
        guard document.supportsChunkStaging, let hunk = document.hunks.first(where: { $0.id == hunkID }) else { throw GitFailure("This change must be staged or unstaged as a whole file.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-patch-\(UUID().uuidString).patch")
        try Data(hunk.patch.utf8).write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let arguments = ["apply", "--cached", "--whitespace=nowarn"] + (reverse ? ["--reverse"] : [])
        _ = try await GitProcess.run(arguments + ["--check", "--", temporary.path], at: root)
        _ = try await GitProcess.run(arguments + ["--", temporary.path], at: root)
    }
}
