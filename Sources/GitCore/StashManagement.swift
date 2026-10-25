import CryptoKit
import Foundation

extension GitRepository {
    public func stashList() async throws -> [Stash] {
        let output = try await GitProcess.run(["stash", "list", "-z", "--format=%H%x00%gd%x00%gs%x00%ct"], at: root)
        let token = SHA256.hash(data: output.data).map { String(format: "%02x", $0) }.joined()
        let fields = output.text.components(separatedBy: "\0")
        var result: [Stash] = [], index = 0
        while index + 3 < fields.count {
            let hash = fields[index].trimmingCharacters(in: .newlines)
            guard hash.count == 40 || hash.count == 64 else { throw GitFailure("Unable to parse the stash list.") }
            result.append(Stash(hash: hash, name: fields[index + 1], subject: fields[index + 2], stackToken: token, date: Date(timeIntervalSince1970: Double(fields[index + 3]) ?? 0)))
            index += 4
        }
        return result
    }

    private func currentStash(_ stash: Stash) async throws -> Stash {
        let list = try await stashList()
        let matches = list.filter { $0.hash == stash.hash && $0.subject == stash.subject }
        if matches.count == 1 { return matches[0] }
        if let match = matches.first(where: { $0.name == stash.name && $0.stackToken == stash.stackToken }) { return match }
        throw GitFailure("The stash was removed, renamed, or is ambiguous after an external change. Refresh before continuing.")
    }

    private func requireStashWorktree() async throws {
        try await requireIdleManagement()
        let changes = GitParser.status(try await GitProcess.run(["status", "--porcelain=v1", "-z"], at: root).data)
        guard !changes.contains(where: \.isConflicted) else { throw GitFailure("Resolve and stage existing conflicts before working with stashes.") }
    }

    @discardableResult public func saveStash(_ options: StashSaveOptions) async throws -> Stash {
        try await requireStashWorktree()
        _ = try await verifiedCommit("HEAD")
        for path in options.paths { try validateInspectionPath(path) }
        let before = try await stashList()
        let message = options.message.isEmpty ? (options.snapshot ? "Snapshot from GitPico" : "Saved from GitPico") : options.message
        var args = ["stash", "push", "-m", message]
        if options.includeUntracked { args.append("--include-untracked") }
        if options.keepIndex && !options.snapshot { args.append("--keep-index") }
        // Per-path literal magic avoids leaking global literal mode into stash's cleanup subprocesses.
        if !options.paths.isEmpty { args += ["--"] + Array(Set(options.paths)).sorted().map { ":(literal)" + $0 } }
        let output = try await GitProcess.run(args, at: root, timeout: 120)
        let after = try await stashList()
        guard let created = after.first, after.count > before.count || (created.hash == before.first?.hash && output.text.hasPrefix("Saved working directory")) else { throw GitFailure("No matching local changes were saved.") }
        if options.snapshot {
            _ = try await GitProcess.run(["stash", "apply", "--index", created.hash], at: root, timeout: 120)
        }
        return created
    }

    public func applyStash(_ stash: Stash, restoreIndex: Bool, deleteAfter: Bool) async throws {
        try await requireStashWorktree()
        let selected = try await currentStash(stash)
        _ = try await backupReference(fullName: "refs/stash", hash: selected.hash, title: selected.subject)
        // Never use `pop` by ordinal: another process can insert a new stash during application.
        _ = try await GitProcess.run(["stash", "apply"] + (restoreIndex ? ["--index"] : []) + [selected.hash], at: root, timeout: 120)
        if deleteAfter { try await deleteStash(selected) }
    }

    public func deleteStash(_ stash: Stash) async throws {
        let selected = try await currentStash(stash)
        _ = try await backupReference(fullName: "refs/stash", hash: selected.hash, title: selected.subject)
        let latest = try await currentStash(selected)
        _ = try await GitProcess.run(["stash", "drop", latest.name], at: root)
    }

    public func deleteAllStashes(expected: [Stash]) async throws {
        let list = try await stashList()
        guard list == expected else { throw GitFailure("The stash stack changed. Reopen the deletion preview.") }
        for stash in list { _ = try await backupReference(fullName: "refs/stash", hash: stash.hash, title: stash.subject) }
        guard try await stashList() == list else { throw GitFailure("The stash stack changed while preparing recovery. Nothing was deleted.") }
        _ = try await GitProcess.run(["stash", "clear"], at: root)
    }

    @discardableResult public func renameStash(_ stash: Stash, message: String) async throws -> Stash {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !message.contains("\n"), !message.utf8.contains(0) else { throw GitFailure("Enter a one-line stash message.") }
        let selected = try await currentStash(stash)
        if selected.subject == message { return selected }
        _ = try await backupReference(fullName: "refs/stash", hash: selected.hash, title: selected.subject)
        let original = try await commit(at: selected.hash)
        let metadata = try await detail(original).metadata
        let date = Int(max(Date().timeIntervalSince1970, metadata.committerDate.timeIntervalSince1970 + 1))
        let identity = ["GIT_AUTHOR_NAME": metadata.author, "GIT_AUTHOR_EMAIL": metadata.authorEmail, "GIT_AUTHOR_DATE": "@\(Int(metadata.authorDate.timeIntervalSince1970)) +0000", "GIT_COMMITTER_NAME": metadata.committer, "GIT_COMMITTER_EMAIL": metadata.committerEmail, "GIT_COMMITTER_DATE": "@\(date) +0000"]
        let renamedHash = try await GitProcess.run(["commit-tree", metadata.tree] + original.parents.flatMap { ["-p", $0] } + ["-m", message], at: root, identityEnvironment: identity).text.trimmingCharacters(in: .newlines)
        let before = try await stashList()
        guard let ordinal = before.firstIndex(where: { $0.id == selected.id }) else { throw GitFailure("The stash stack changed.") }
        _ = try await GitProcess.run(["stash", "store", "-m", message, renamedHash], at: root)
        let after = try await stashList()
        guard after.count == before.count + 1,
              Array(after.dropFirst().map { $0.hash + "\0" + $0.subject }) == before.map({ $0.hash + "\0" + $0.subject }) else {
            throw GitFailure("The stash stack changed while renaming. Both entries were retained; refresh to inspect them.")
        }
        _ = try await GitProcess.run(["stash", "drop", after[ordinal + 1].name], at: root)
        guard let result = try await stashList().first else { throw GitFailure("Reload the stash list to inspect the renamed entry.") }
        return result
    }

    public func branchFromStash(_ stash: Stash, name: String) async throws {
        try await requireStashWorktree(); try await requireCleanHistoryWorktree(); try await validateReferenceName(name)
        let selected = try await currentStash(stash)
        _ = try await backupReference(fullName: "refs/stash", hash: selected.hash, title: selected.subject)
        _ = try await GitProcess.run(["stash", "branch", name, selected.hash], at: root, timeout: 120)
        try await deleteStash(selected)
    }

    public func stashDetail(_ stash: Stash) async throws -> StashDetail {
        let commit = try await commit(at: stash.hash)
        guard commit.parents.count >= 2 else { throw GitFailure("This object is not a valid stash.") }
        let base = commit.parents[0]
        let names = try await GitProcess.run(["diff", "--name-status", "--find-renames", "-z", base, stash.hash, "--"], at: root).text.components(separatedBy: "\0")
        var files: [StashFile] = [], index = 0
        while index + 1 < names.count {
            let status = names[index]; let old = names[index + 1]; index += 2
            guard !status.isEmpty else { break }
            if status.hasPrefix("R") || status.hasPrefix("C"), index < names.count {
                files.append(StashFile(path: names[index], originalPath: old, status: status, isUntracked: false)); index += 1
            } else { files.append(StashFile(path: old, originalPath: nil, status: status, isUntracked: false)) }
        }
        var statistics = GitParser.statistics(try await GitProcess.run(["diff", "--numstat", "--find-renames", "-z", base, stash.hash, "--"], at: root).data)
        if commit.parents.count >= 3 {
            let untracked = try await fileTree(at: commit.parents[2])
            files += untracked.map { StashFile(path: $0, originalPath: nil, status: "A", isUntracked: true) }
            let extra = try await GitProcess.run(["diff-tree", "--root", "--no-commit-id", "-r", "--numstat", "-z", commit.parents[2], "--"], at: root)
            statistics.merge(GitParser.statistics(extra.data)) { _, new in new }
        }
        return StashDetail(commit: commit, base: base, files: files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, statistics: statistics)
    }

    public func stashFileDiff(_ stash: Stash, file: StashFile) async throws -> String {
        let detail = try await stashDetail(stash)
        guard detail.files.contains(where: { $0.path == file.path && $0.originalPath == file.originalPath && $0.isUntracked == file.isUntracked }) else { throw GitFailure("Reload this stash before inspecting the file.") }
        let paths = Array(Set([file.path, file.originalPath].compactMap { $0 })).sorted()
        if file.isUntracked {
            return try await GitProcess.run(["show", "--format=", "--no-show-signature", "--no-ext-diff", "--no-textconv", "--binary", "--full-index", "--unified=7", detail.commit.parents[2], "--"] + paths, at: root).text
        }
        return try await GitProcess.run(["diff", "--no-ext-diff", "--no-textconv", "--binary", "--full-index", "--find-renames", "--unified=7", detail.base, stash.hash, "--"] + paths, at: root).text
    }

    public func applyStashFiles(_ stash: Stash, paths: [String]) async throws {
        try await requireStashWorktree()
        let selected = try await currentStash(stash), detail = try await stashDetail(selected)
        guard !paths.isEmpty, Set(paths).isSubset(of: Set(detail.files.map(\.path))) else { throw GitFailure("Choose files from this stash.") }
        var patch = ""
        for file in detail.files where paths.contains(file.path) { patch += try await stashFileDiff(selected, file: file) }
        try await applyStashPatch(patch)
    }

    public func applyStashHunk(_ stash: Stash, file: StashFile, renderedDiff: String, hunkID: Int) async throws {
        try await requireStashWorktree()
        let selected = try await currentStash(stash)
        guard try await stashFileDiff(selected, file: file) == renderedDiff else { throw GitFailure("The stash preview changed. Reload before applying a chunk.") }
        let document = PatchDocument(renderedDiff)
        guard document.supportsChunkStaging, let hunk = document.hunks.first(where: { $0.id == hunkID }) else { throw GitFailure("Apply this structural or binary change as a whole file.") }
        try await applyStashPatch(hunk.patch)
    }

    public func applyStashLines(_ stash: Stash, file: StashFile, renderedDiff: String, selection: Set<PatchLineID>) async throws {
        try await requireStashWorktree()
        let selected = try await currentStash(stash)
        guard try await stashFileDiff(selected, file: file) == renderedDiff else { throw GitFailure("The stash preview changed. Reload before applying selected lines.") }
        let document = PatchDocument(renderedDiff)
        let visible = Set(document.preview().filter { !$0.isTruncated }.flatMap { preview in
            preview.lines.compactMap { line -> PatchLineID? in
                line.kind == .addition || line.kind == .deletion ? PatchLineID(hunk: preview.hunk.id, line: line.id) : nil
            }
        })
        guard selection.isSubset(of: visible) else { throw GitFailure("Select lines from a complete visible text chunk.") }
        try await applyStashPatch(document.selectedPatch(selection, reverse: false))
    }

    private func applyStashPatch(_ patch: String) async throws {
        guard !patch.isEmpty else { throw GitFailure("There are no changes to apply.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-stash-" + UUID().uuidString + ".patch")
        try Data(patch.utf8).write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try await GitProcess.run(["apply", "--check", "--whitespace=nowarn", "--", temporary.path], at: root)
        _ = try await GitProcess.run(["apply", "--whitespace=nowarn", "--", temporary.path], at: root)
    }
}
