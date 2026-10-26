import Foundation

public actor GitRepository {
    public let root: URL
    public init(root: URL) { self.root = root }

    public static func open(_ url: URL) async throws -> GitRepository {
        let result = try await GitProcess.run(["rev-parse", "--show-toplevel"], at: url)
        guard var path = String(data: result.data, encoding: .utf8), path.last == "\n" else { throw GitFailure("Git returned an unsupported working-directory path.") }
        // Remove Git's terminator, preserving newlines that belong to the directory.
        path.removeLast()
        guard !path.isEmpty, !path.utf8.contains(0) else { throw GitFailure("Choose a non-bare Git working directory.") }
        return GitRepository(root: URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath())
    }

    public func snapshot(ref: String? = nil, options: HistoryOptions = HistoryOptions(), countHistory: Bool = true) async throws -> RepositorySnapshot {
        async let status = GitProcess.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root)
        async let refs = GitProcess.run(["for-each-ref", "--sort=refname", "--format=%(refname)%00%(objectname)%00%(symref)%00%(upstream:short)%00%(HEAD)", "refs/heads", "refs/remotes", "refs/tags"], at: root)
        async let branch = GitProcess.run(["symbolic-ref", "--quiet", "HEAD"], at: root, allowed: [0, 1])
        async let head = GitProcess.run(["rev-parse", "--verify", "--quiet", "HEAD"], at: root, allowed: [0, 1])
        async let remotes = GitProcess.run(["remote"], at: root)
        async let stashes = stashList()
        let (statusOutput, refsOutput, branchOutput, headOutput, remotesOutput, stashOutput) = try await (status, refs, branch, head, remotes, stashes)
        let hasHEAD = headOutput.status == 0
        let references = GitParser.references(refsOutput.data)
        let selectors = ref.map { [$0, "--"] }
            ?? ["--branches", "--remotes", "--tags"] + (hasHEAD ? ["HEAD"] : []) + ["--"]
        let filters = (options.firstParent ? ["--first-parent"] : [])
            + (options.query.isEmpty ? [] : ["--regexp-ignore-case", "--fixed-strings", "--grep=" + options.query])
        let commits: [Commit]
        let historyCount: Int
        if hasHEAD || !references.isEmpty {
            let output = try await GitProcess.run(["log", "--no-show-signature", options.sortByDate ? "--date-order" : "--topo-order", "--max-count=\(options.limit)", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%D%x00"] + filters + selectors, at: root)
            commits = GitParser.commits(output.data)
            if countHistory {
                let count = try await GitProcess.run(["rev-list", "--count"] + filters + selectors, at: root)
                historyCount = Int(count.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? commits.count
            } else { historyCount = commits.count }
        } else { commits = []; historyCount = 0 }
        async let identity = readIdentity()
        async let operation = currentOperation()
        var ahead = 0
        var behind = 0
        if references.contains(where: { $0.isCurrent && !$0.upstream.isEmpty }) {
            let counts = try await GitProcess.run(["rev-list", "--left-right", "--count", "HEAD...@{upstream}", "--"], at: root)
            let values = counts.text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            if values.count == 2 { ahead = values[0]; behind = values[1] }
        }
        return RepositorySnapshot(root: root, branch: branchOutput.status == 0 ? branchOutput.text.trimmingCharacters(in: .newlines).replacingOccurrences(of: "^refs/heads/", with: "", options: .regularExpression) : "Detached HEAD", changes: GitParser.status(statusOutput.data), commits: commits, references: references, stashes: stashOutput, remotes: remotesOutput.text.split(separator: "\n").map(String.init), ahead: ahead, behind: behind, hasHEAD: hasHEAD, identity: try await identity, operation: try await operation, historyCount: historyCount, head: HeadPosition(branch: branchOutput.status == 0 ? branchOutput.text.trimmingCharacters(in: .newlines) : "HEAD", hash: hasHEAD ? headOutput.text.trimmingCharacters(in: .newlines) : nil), historyCountIsExact: countHistory || commits.count < options.limit)
    }

    public func diff(_ change: FileChange, staged: Bool, context: Int = 7, ignoreWhitespace: Bool = false, cancellable: Bool = false) async throws -> String {
        let options = ["--unified=\(context)"] + (ignoreWhitespace ? ["--ignore-all-space"] : [])
        if staged && change.isUntracked { return "" }
        if change.isUntracked {
            return try await GitProcess.run(["diff", "--no-ext-diff", "--no-textconv"] + options + ["--no-index", "--", "/dev/null", change.path], at: root, allowed: [0, 1], cancellable: cancellable).text
        }
        let paths = [change.originalPath, change.path].compactMap { $0 }
        return try await GitProcess.run(["diff", "--no-ext-diff", "--no-textconv"] + options + (staged ? ["--cached"] : []) + ["--"] + paths, at: root, cancellable: cancellable).text
    }

    public func detail(_ commit: Commit, cancellable: Bool = false) async throws -> CommitDetail {
        async let message = GitProcess.run(["show", "--no-show-signature", "-s", "--format=%B", commit.hash, "--"], at: root, cancellable: cancellable)
        let files: GitOutput
        if let parent = commit.parents.first {
            files = try await GitProcess.run(["diff", "--name-status", "-z", "--find-renames", parent, commit.hash, "--"], at: root, cancellable: cancellable)
        } else {
            files = try await GitProcess.run(["diff-tree", "--root", "--no-commit-id", "-r", "--name-status", "-z", commit.hash, "--"], at: root, cancellable: cancellable)
        }
        let metadata = try await GitProcess.run(["show", "--no-show-signature", "-s", "--format=%an%x00%ae%x00%at%x00%cn%x00%ce%x00%ct%x00%T", commit.hash, "--"], at: root, cancellable: cancellable)
        let values = metadata.text.trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard values.count == 7 else { throw GitFailure("Unable to parse commit metadata.") }
        let statsArgs = commit.parents.first.map { ["diff", "--numstat", "-z", $0, commit.hash, "--"] }
            ?? ["diff-tree", "--root", "--no-commit-id", "-r", "--numstat", "-z", commit.hash, "--"]
        let stats = try await GitProcess.run(statsArgs, at: root, cancellable: cancellable)
        let info = CommitMetadata(author: values[0], authorEmail: values[1], authorDate: Date(timeIntervalSince1970: Double(values[2]) ?? 0), committer: values[3], committerEmail: values[4], committerDate: Date(timeIntervalSince1970: Double(values[5]) ?? 0), tree: values[6])
        return CommitDetail(message: try await message.text.trimmingCharacters(in: .newlines), files: GitParser.changedPaths(files.data), metadata: info, statistics: GitParser.statistics(stats.data))
    }

    public func commitDiff(_ commit: Commit, path: String, cancellable: Bool = false) async throws -> String {
        if let parent = commit.parents.first {
            return try await GitProcess.run(["diff", "--no-ext-diff", "--no-textconv", "--unified=7", "--find-renames", parent, commit.hash, "--", path], at: root, cancellable: cancellable).text
        }
        return try await GitProcess.run(["show", "--no-show-signature", "--format=", "--no-ext-diff", "--no-textconv", "--unified=7", commit.hash, "--", path], at: root, cancellable: cancellable).text
    }

    public func stage(_ changes: [FileChange]) async throws {
        let paths = Array(Set(changes.filter { $0.isUnstaged || $0.isConflicted }.flatMap { [$0.originalPath, $0.path].compactMap { $0 } })).sorted()
        guard !paths.isEmpty else { return }
        _ = try await GitProcess.run(["add", "--all", "--"] + paths, at: root)
    }

    public func unstage(_ changes: [FileChange]) async throws {
        let paths = Array(Set(changes.flatMap { [$0.originalPath, $0.path].compactMap { $0 } })).sorted()
        guard !paths.isEmpty else { return }
        let head = try await GitProcess.run(["rev-parse", "--verify", "--quiet", "HEAD"], at: root, allowed: [0, 1])
        if head.status == 0 {
            _ = try await GitProcess.run(["restore", "--staged", "--"] + paths, at: root)
        } else {
            _ = try await GitProcess.run(["rm", "--cached", "-f", "--"] + paths, at: root)
        }
    }

    @discardableResult public func commit(message: String, amend: Bool = false, signOff: Bool = false) async throws -> CommitOutcome {
        let before = try await headPosition()
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitFailure("Enter a commit message.") }
        let changes = GitParser.status(try await GitProcess.run(["status", "--porcelain=v1", "-z"], at: root).data)
        guard !changes.contains(where: \.isConflicted) else { throw GitFailure("Resolve all conflicts before committing.") }
        guard amend || changes.contains(where: \.isStaged) else { throw GitFailure("Stage at least one change before committing.") }
        _ = try await GitProcess.run(["commit"] + (amend ? ["--amend"] : []) + (signOff ? ["--signoff"] : []) + ["-m", message], at: root, timeout: 120)
        do {
            try await recordHistory(before, title: amend ? "Amend Commit" : "Commit", restoresFiles: false)
            return CommitOutcome(undoWarning: nil)
        } catch {
            // Git has already created the commit. A local journal failure must not invite a retry.
            return CommitOutcome(undoWarning: "The commit was created, but its Undo record could not be saved. " + error.localizedDescription)
        }
    }

    public func switchBranch(_ name: String) async throws {
        _ = try await GitProcess.run(["switch", "--", name], at: root)
    }

    public func createBranch(_ name: String) async throws {
        _ = try await GitProcess.run(["check-ref-format", "--branch", name], at: root)
        _ = try await GitProcess.run(["switch", "-c", name], at: root)
    }

    public enum SyncAction: String, Sendable { case fetch, pull, push }
    public func sync(_ action: SyncAction) async throws {
        let arguments: [String]
        switch action {
        case .fetch: arguments = ["fetch", "--all"]
        case .pull: arguments = ["pull", "--ff-only"]
        case .push: arguments = ["push"]
        }
        _ = try await GitProcess.run(arguments, at: root, timeout: 120)
    }

    public func saveStash(message: String) async throws {
        var options = StashSaveOptions(); options.message = message
        _ = try await saveStash(options)
    }

    public func stashDiff(_ stash: Stash) async throws -> String {
        try await GitProcess.run(["stash", "show", "--patch", "--include-untracked", "--no-ext-diff", "--no-textconv", stash.hash], at: root).text
    }

    public func applyStash(_ stash: Stash) async throws {
        try await applyStash(stash, restoreIndex: false, deleteAfter: false)
    }
}
