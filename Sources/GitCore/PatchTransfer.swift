import Foundation

public enum PatchDestination: String, CaseIterable, Sendable {
    case workingCopy, index, both
    public var title: String {
        switch self { case .workingCopy: "Working Copy"; case .index: "Index Only"; case .both: "Working Copy and Index" }
    }
}

public enum PatchExportSource: Sendable {
    case unstaged, staged, commit(String)
}

extension GitRepository {
    /// Git parses quoted names, renames, binary records and mailbox envelopes for us.
    func patchPaths(_ data: Data) async throws -> [String] {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw GitFailure("Choose a nonempty patch up to 16 MB.") }
        let output = try await GitProcess.run(["apply", "--numstat", "-z", "-"], at: root, input: data)
        guard let text = String(data: output.data, encoding: .utf8) else { throw GitFailure("The patch uses unsupported filename encoding.") }
        let fields = text.components(separatedBy: "\0")
        var index = 0, paths: Set<String> = []
        while index < fields.count, !fields[index].isEmpty {
            let stat = fields[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false); index += 1
            guard stat.count == 3 else { throw GitFailure("Invalid patch statistics.") }
            if stat[2].isEmpty {
                guard index + 1 < fields.count, !fields[index].isEmpty, !fields[index + 1].isEmpty else { throw GitFailure("Incomplete patch rename.") }
                paths.insert(fields[index]); paths.insert(fields[index + 1]); index += 2
            } else { paths.insert(String(stat[2])) }
        }
        // git apply --numstat reports only the destination of a rename/copy.
        // Extended headers are unprefixed, unlike source lines inside a hunk.
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
            for prefix in ["rename from ", "copy from "] where line.hasPrefix(prefix) {
                paths.insert(InspectionParser.decodeGitPath(String(line.dropFirst(prefix.count))))
            }
        }
        guard !paths.isEmpty else { throw GitFailure("The patch contains no file changes.") }
        return paths.sorted()
    }

    public func previewPatch(_ data: Data, destination: PatchDestination, reverse: Bool = false) async throws -> LocalChangePlan {
        let paths = try await patchPaths(data)
        try await requireLocalChangeSupport(paths, allowStructural: true)
        if destination != .index {
            let autocrlf = try await GitProcess.run(["config", "--get", "core.autocrlf"], at: root, allowed: [0, 1]).text.trimmingCharacters(in: .newlines)
            let attributes = try await GitProcess.run(["check-attr", "-z", "--stdin", "filter", "working-tree-encoding", "text", "eol"], at: root, input: Data((paths.joined(separator: "\0") + "\0").utf8)).text.components(separatedBy: "\0")
            let converted = stride(from: 2, to: attributes.count, by: 3).contains { !["unspecified", "unset"].contains(attributes[$0]) }
            guard autocrlf != "true", !converted else { throw GitFailure("Worktree patch application requires files without text/eol attributes, encoding or clean/smudge conversion. Choose Index Only, or apply this patch with Git.") }
        }
        let head = try await headPosition(), beforeIndex = try readLocalIndex(try await localIndexURL()), before = try localFiles(paths)
        let directory = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let temporaryIndex = try await scratchIndex(beforeIndex, in: directory)
        let options = ["--binary", "--whitespace=nowarn"] + (reverse ? ["--reverse"] : [])
        if destination == .both {
            // Refresh stat information only in the owned index: identical bytes can
            // otherwise fail --index after an editor's atomic replacement.
            _ = try await GitProcess.run(["update-index", "--refresh"], at: root, allowed: [0, 1], indexFile: temporaryIndex)
            _ = try await GitProcess.run(["apply", "--index", "--check"] + options + ["-"], at: root, input: data, indexFile: temporaryIndex)
        }
        if destination != .workingCopy {
            _ = try await GitProcess.run(["apply", "--cached", "--check"] + options + ["-"], at: root, input: data, indexFile: temporaryIndex)
            _ = try await GitProcess.run(["apply", "--cached"] + options + ["-"], at: root, input: data, indexFile: temporaryIndex)
            let entries = try await GitProcess.run(["ls-files", "--stage", "-z", "--"] + paths, at: root, indexFile: temporaryIndex).text.components(separatedBy: "\0")
            if destination != .index, entries.contains(where: { $0.hasPrefix("160000 ") }) { throw GitFailure("Submodule patches update recorded commits. Choose Index Only to preserve nested working files, then update submodules separately.") }
        }
        var after = before
        if destination != .index {
            guard !before.contains(where: { $0.directory == true }) else { throw GitFailure("Choose Index Only for a patch affecting a submodule directory.") }
            let worktree = directory.appendingPathComponent("worktree")
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            _ = try await GitProcess.run(["init", "-q", "-b", "main"], at: worktree)
            for state in before { try writeLocalFile(state, in: worktree) }
            // The sandbox has no hooks, remotes, attributes or executable filters.
            _ = try await GitProcess.run(["apply", "--check"] + options + ["-"], at: worktree, input: data)
            _ = try await GitProcess.run(["apply"] + options + ["-"], at: worktree, input: data)
            after = try localFiles(paths, in: worktree)
            // A patch must not smuggle an additional destination past the numstat parser.
            let actual = try await GitProcess.run(["ls-files", "--others", "--exclude-standard", "-z"], at: worktree).text.components(separatedBy: "\0").filter { !$0.isEmpty }
            guard Set(actual).isSubset(of: Set(paths)) else { throw GitFailure("The patch writes undeclared paths.") }
        }
        let afterIndex = destination == .workingCopy ? beforeIndex : try readLocalIndex(temporaryIndex)
        return LocalChangePlan(id: UUID(), title: reverse ? "Apply Reversed Patch" : "Apply Patch", paths: paths,
                               preview: String(decoding: data.prefix(256 * 1024), as: UTF8.self), repository: root.path, head: head,
                               beforeIndex: beforeIndex, afterIndex: afterIndex, before: before, after: after)
    }

    public func previewDiscardLines(_ change: FileChange, renderedDiff: String, selection: Set<PatchLineID>, context: Int = 7) async throws -> LocalChangePlan {
        let fresh = try await diff(change, staged: false, context: context)
        guard fresh == renderedDiff, !change.isConflicted else { throw GitFailure("The file changed. Refresh the diff before discarding lines.") }
        let patch = try PatchDocument(fresh).selectedPatch(selection, reverse: true)
        let plan = try await previewPatch(Data(patch.utf8), destination: .workingCopy)
        return LocalChangePlan(id: plan.id, title: "Discard Selected Lines", paths: plan.paths, preview: patch, repository: plan.repository, head: plan.head,
                               beforeIndex: plan.beforeIndex, afterIndex: plan.afterIndex, before: plan.before, after: plan.after)
    }

    public func previewDiscardChunk(_ change: FileChange, renderedDiff: String, hunkID: Int, context: Int = 7) async throws -> LocalChangePlan {
        let fresh = try await diff(change, staged: false, context: context), document = PatchDocument(fresh)
        guard fresh == renderedDiff, document.supportsChunkStaging, let hunk = document.hunks.first(where: { $0.id == hunkID }), !change.isConflicted else {
            throw GitFailure("The chunk changed or cannot be discarded separately. Refresh the diff.")
        }
        let plan = try await previewPatch(Data(hunk.patch.utf8), destination: .workingCopy, reverse: true)
        return LocalChangePlan(id: plan.id, title: "Discard Chunk", paths: plan.paths, preview: hunk.patch, repository: plan.repository, head: plan.head,
                               beforeIndex: plan.beforeIndex, afterIndex: plan.afterIndex, before: plan.before, after: plan.after)
    }

    public func exportPatch(_ source: PatchExportSource, paths: [String] = []) async throws -> Data {
        for path in paths { _ = try validateLocalPath(path) }
        let options = ["--no-ext-diff", "--no-textconv", "--binary", "--full-index", "--no-color", "--no-renames"]
        let result: Data
        switch source {
        case .commit(let revision):
            let hash = try await verifiedCommit(revision)
            let commit = try await commit(at: hash)
            guard commit.parents.count <= 1 else { throw GitFailure("Choose a non-merge commit for mailbox patch export.") }
            return try await GitProcess.run(["format-patch", "--stdout", "--no-signature", "--no-stat", "--no-ext-diff", "--no-textconv", "--binary", "--full-index", "--root", "-1", hash, "--"] + paths.map { ":(literal)" + $0 }, at: root).data
        case .staged:
            result = try await GitProcess.run(["diff", "--cached"] + options + ["--"] + paths, at: root).data
        case .unstaged:
            var data = try await GitProcess.run(["diff"] + options + ["--"] + paths, at: root).data
            let status = GitParser.status(try await GitProcess.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root).data)
            for change in status where change.isUntracked && (paths.isEmpty || paths.contains(change.path)) {
                _ = try localFiles([change.path])
                data.append(try await GitProcess.run(["diff", "--no-index"] + options + ["--", "/dev/null", change.path], at: root, allowed: [0, 1]).data)
            }
            result = data
        }
        guard !result.isEmpty else { throw GitFailure("There are no changes in this export scope.") }
        guard result.count <= 16 * 1024 * 1024 else { throw GitFailure("The patch exceeds 16 MB. Export fewer files at a time.") }
        return result
    }

    public func exportSelectedLines(_ change: FileChange, renderedDiff: String, selection: Set<PatchLineID>, staged: Bool, context: Int = 7) async throws -> Data {
        guard try await diff(change, staged: staged, context: context) == renderedDiff else { throw GitFailure("The diff changed. Select the lines again.") }
        return Data(try PatchDocument(renderedDiff).selectedPatch(selection, reverse: false).utf8)
    }
}
