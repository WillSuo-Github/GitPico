import Foundation

public struct IncrementalSnapshot: Sendable {
    public let snapshot: RepositorySnapshot
    public let headChanged: Bool
    public let browserFiles: [WorkingFileEntry]?
}

extension GitRepository {
    public func incrementalSnapshot(from previous: RepositorySnapshot, history: Bool, browser: Bool = false, ignored: Bool = false, rescanIgnored: Bool = false, options: HistoryOptions = HistoryOptions()) async throws -> IncrementalSnapshot {
        guard previous.root == root else { throw GitFailure("The repository changed before refreshing its working copy.") }
        // Detect a moving HEAD instead of combining status from one branch with another branch's header.
        for _ in 0..<3 {
            let before = try await headPosition()
            async let status = GitProcess.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root)
            async let operation = currentOperation()
            let changes = GitParser.status(try await status.data), state = try await operation
            let headChanged = previous.head != before
            var refs = previous.references, commits = previous.commits
            var ahead = previous.ahead, behind = previous.behind, count = previous.historyCount, exact = previous.historyCountIsExact
            var identity = previous.identity
            if history || headChanged {
                refs = try await references()
                var pageOptions = options; pageOptions.limit = min(500, options.limit)
                let page = try await historyPage(at: .all(references: refs, head: before), options: pageOptions)
                commits = page.commits; count = page.totalCount ?? page.commits.count; exact = page.totalCount != nil
                ahead = 0; behind = 0
                if refs.contains(where: { $0.isCurrent && !$0.upstream.isEmpty }) {
                    let counts = try await GitProcess.run(["rev-list", "--left-right", "--count", "HEAD...@{upstream}", "--"], at: root).text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
                    guard counts.count == 2 else { throw GitFailure("Unable to read upstream divergence.") }
                    ahead = counts[0]; behind = counts[1]
                }
                identity = try await readIdentity()
            }
            let files: [WorkingFileEntry]?
            if browser {
                files = ignored || rescanIgnored ? try await workingFiles(includeIgnored: ignored) : try await indexedWorkingFiles(changes: changes)
            } else { files = nil }
            guard try await headPosition() == before else { continue }
            let branch = before.branch == "HEAD" ? "Detached HEAD" : (before.branch.hasPrefix("refs/heads/") ? String(before.branch.dropFirst("refs/heads/".count)) : before.branch)
            let snapshot = RepositorySnapshot(root: root, branch: branch, changes: changes, commits: commits, references: refs, stashes: previous.stashes, remotes: previous.remotes, ahead: ahead, behind: behind, hasHEAD: before.hash != nil, identity: identity, operation: state, historyCount: count, head: before, historyCountIsExact: exact)
            return IncrementalSnapshot(snapshot: snapshot, headChanged: headChanged, browserFiles: files)
        }
        throw GitFailure("HEAD kept changing during refresh. Refresh again when the other operation finishes.")
    }
    private func indexedWorkingFiles(changes: [FileChange]) async throws -> [WorkingFileEntry] {
        let data = try await GitProcess.run(["ls-files", "-v", "-z", "--cached", "--"], at: root).data
        guard let text = String(data: data, encoding: .utf8) else { throw GitFailure("File browsing requires UTF-8 filenames.") }
        var flags: [String:Character] = [:]
        for record in text.split(separator: "\0") {
            guard record.count >= 3, let flag = record.first else { throw GitFailure("Invalid tracked-file entry.") }
            flags[String(record.dropFirst(2))] = flag
        }
        let byPath = Dictionary(changes.map { ($0.path,$0) }, uniquingKeysWith: { first,_ in first })
        let paths = Set(flags.keys).union(changes.map(\.path))
        guard paths.count <= 50_000 else { throw GitFailure("The working file list exceeds its entry limit. Use a smaller working tree.") }
        return paths.map { path in WorkingFileEntry(path: path, change: byPath[path], isTracked: flags[path] != nil, isIgnored: false, assumeUnchanged: flags[path]?.isLowercase == true, skipWorktree: flags[path].map { String($0).uppercased() == "S" } ?? false) }
    }
}

extension RepositorySnapshot {
    public func replacingMetadata(remotes: [String]? = nil, stashes: [Stash]? = nil) -> Self {
        Self(root: root, branch: branch, changes: changes, commits: commits, references: references, stashes: stashes ?? self.stashes, remotes: remotes ?? self.remotes, ahead: ahead, behind: behind, hasHEAD: hasHEAD, identity: identity, operation: operation, historyCount: historyCount, head: head, historyCountIsExact: historyCountIsExact)
    }
}
