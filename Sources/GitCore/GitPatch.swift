import Foundation

public struct PatchHunk: Identifiable, Sendable {
    public let id: Int
    public let header: String
    public let text: String
    public let patch: String
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

    public init(_ text: String) {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let starts = lines.indices.filter { lines[$0].hasPrefix("@@ ") }
        let header = Array(lines.prefix(starts.first ?? lines.count))
        hunks = starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1] : lines.count
            let content = Array(lines[start..<end])
            return PatchHunk(id: offset, header: lines[start], text: content.joined(separator: "\n"), patch: (header + content).joined(separator: "\n") + "\n")
        }
        var inHunk = false
        var added = 0; var removed = 0
        for line in lines {
            if line.hasPrefix("diff --git ") { inHunk = false }
            else if line.hasPrefix("@@ ") { inHunk = true }
            else if inHunk && line.hasPrefix("+") { added += 1 }
            else if inHunk && line.hasPrefix("-") { removed += 1 }
        }
        additions = added; deletions = removed
        let structural = header.contains { $0.hasPrefix("rename ") || $0.hasPrefix("copy ") || $0.hasPrefix("old mode") || $0.hasPrefix("new mode") }
        let deletion = header.contains { $0.hasPrefix("deleted file mode") }
        supportsChunkStaging = !hunks.isEmpty && !structural && !(deletion && hunks.count > 1) && lines.filter { $0.hasPrefix("diff --git ") }.count == 1
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
