import Foundation

public struct PatchLineID: Hashable, Sendable {
    public let hunk: Int
    public let line: Int
    public init(hunk: Int, line: Int) { self.hunk = hunk; self.line = line }
}

extension PatchDocument {
    public var selectableLines: Set<PatchLineID> {
        Set(hunks.flatMap { hunk in
            DiffDocument(hunk.text, limit: Int.max).lines.compactMap { line in
                line.kind == .addition || line.kind == .deletion ? PatchLineID(hunk: hunk.id, line: line.id) : nil
            }
        })
    }

    public func selectedPatch(_ selection: Set<PatchLineID>, reverse: Bool) throws -> String {
        guard supportsChunkStaging, !selection.isEmpty, selection.isSubset(of: selectableLines) else {
            throw GitFailure("Select changed lines from a text diff without rename or mode changes.")
        }
        let first = hunks[0].patch.components(separatedBy: "\n")
        let header = Array(first.prefix { !$0.hasPrefix("@@ ") })
        let newFile = header.first { $0.hasPrefix("new file mode ") }
        let deletedFile = header.first { $0.hasPrefix("deleted file mode ") }
        let all = selection == selectableLines
        let sourceMissing = reverse ? deletedFile != nil : newFile != nil
        let resultMissing = all && (reverse ? newFile != nil : deletedFile != nil)
        func path(_ prefix: String, fallback: String) -> String {
            let value = String((header.first { $0.hasPrefix(prefix) } ?? "").dropFirst(4))
            if value != "/dev/null" { return value }
            var other = String((header.first { $0.hasPrefix(fallback) } ?? "").dropFirst(4))
            let wanted = prefix == "--- " ? "a/" : "b/"
            if other.hasPrefix("\"") { other.replaceSubrange(other.index(after: other.startIndex)..<other.index(other.startIndex, offsetBy: 3), with: wanted) }
            else if other.count >= 2 { other.replaceSubrange(other.startIndex..<other.index(other.startIndex, offsetBy: 2), with: wanted) }
            return other
        }
        var output = header.filter { $0.hasPrefix("diff --git ") }
        let mode = (newFile ?? deletedFile)?.split(separator: " ").last.map(String.init) ?? "100644"
        if sourceMissing { output.append("new file mode \(mode)") }
        if resultMissing { output.append("deleted file mode \(mode)") }
        output.append("--- " + (sourceMissing ? "/dev/null" : path("--- ", fallback: "+++ ")))
        output.append("+++ " + (resultMissing ? "/dev/null" : path("+++ ", fallback: "--- ")))
        var delta = 0
        for hunk in hunks {
            let ranges = hunk.header.split(separator: " ")
            guard ranges.count >= 4 else { throw GitFailure("Invalid diff chunk.") }
            let range = ranges[reverse ? 2 : 1].dropFirst().split(separator: ",")
            guard let start = Int(range[0]) else { throw GitFailure("Invalid diff range.") }
            let originalCount = range.count > 1 ? Int(range[1]) ?? 0 : 1
            let anchor = start + (originalCount == 0 ? 1 : 0)
            var body: [String] = []
            var changed = false
            var previousIncluded = false
            for line in DiffDocument(hunk.text, limit: Int.max).lines.dropFirst() {
                let chosen = selection.contains(PatchLineID(hunk: hunk.id, line: line.id))
                switch line.kind {
                case .addition, .deletion:
                    let sourceOnly = reverse ? line.kind == .addition : line.kind == .deletion
                    if chosen {
                        body.append((sourceOnly ? "-" : "+") + line.text.dropFirst()); changed = true; previousIncluded = true
                    } else if sourceOnly {
                        body.append(" " + line.text.dropFirst()); previousIncluded = true
                    } else { previousIncluded = false }
                case .context: body.append(line.text); previousIncluded = true
                default:
                    if line.text.hasPrefix("\\ No newline"), previousIncluded { body.append(line.text) }
                }
            }
            guard changed else { continue }
            let oldCount = body.filter { $0.hasPrefix(" ") || $0.hasPrefix("-") }.count
            let newCount = body.filter { $0.hasPrefix(" ") || $0.hasPrefix("+") }.count
            let oldStart = anchor - (oldCount == 0 ? 1 : 0)
            let newStart = anchor + delta - (newCount == 0 ? 1 : 0)
            output.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            output += body
            delta += newCount - oldCount
        }
        return output.joined(separator: "\n") + "\n"
    }
}

extension GitRepository {
    public func stageLines(_ change: FileChange, renderedDiff: String, selection: Set<PatchLineID>, reverse: Bool, context: Int = 7) async throws {
        guard !change.isConflicted else { throw GitFailure("Resolve the conflict before staging lines.") }
        guard try await diff(change, staged: reverse, context: context) == renderedDiff else {
            throw GitFailure("The file or index changed. Refresh before staging selected lines.")
        }
        let patch = try PatchDocument(renderedDiff).selectedPatch(selection, reverse: reverse)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-lines-\(UUID().uuidString).patch")
        try Data(patch.utf8).write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let arguments = ["apply", "--cached", "--whitespace=nowarn"]
        _ = try await GitProcess.run(arguments + ["--check", "--", temporary.path], at: root)
        _ = try await GitProcess.run(arguments + ["--", temporary.path], at: root)
    }
}
