import Foundation

extension GitRepository {
    public func skipIntegrationStep() async throws {
        let operation = try await currentOperation()
        guard operation == .cherryPick || operation == .revert else { throw GitFailure("There is no Cherry-Pick or Revert step to skip.") }
        _ = try await GitProcess.run([operation == .cherryPick ? "cherry-pick" : "revert", "--skip"], at: root, timeout: 120, acceptGeneratedMessage: true)
        try await finishHistoryAction()
        try await finishAutomaticStashIfReady()
    }
    /// One native sequencer and one undo record cover the whole reviewed sequence.
    public func integrateBatch(_ action: Integration, revisions: [String], mainline: Int? = nil, expectedHead: HeadPosition) async throws {
        guard action == .cherryPick || action == .revert, (1...200).contains(revisions.count),
              Set(revisions).count == revisions.count else { throw GitFailure("Choose 1–200 distinct commits for Cherry-Pick or Revert.") }
        guard try await headPosition() == expectedHead else { throw GitFailure("HEAD changed. Reopen the batch preview.") }
        try await requireCleanHistoryWorktree()
        guard try await currentOperation() == .none else { throw GitFailure("Finish or abort the current operation first.") }
        var targets: [String] = []
        for revision in revisions {
            guard [40, 64].contains(revision.count), revision.allSatisfy(\.isHexDigit) else { throw GitFailure("Batch operations require captured commit hashes.") }
            let commit = try await commit(at: revision)
            if commit.parents.count > 1 {
                guard let mainline, (1...commit.parents.count).contains(mainline) else { throw GitFailure("Choose a valid mainline parent for every merge commit in the batch.") }
            }
            let parent = commit.parents.isEmpty ? nil : commit.parents[(commit.parents.count > 1 ? (mainline ?? 1) : 1) - 1]
            try await protectBatchAdditions(action, commit: commit.hash, parent: parent)
            targets.append(commit.hash)
        }
        guard Set(targets).count == targets.count else { throw GitFailure("The batch contains duplicate commits.") }
        guard try await headPosition() == expectedHead else { throw GitFailure("HEAD changed. Reopen the batch preview.") }
        let operation: RepositoryOperation = action == .cherryPick ? .cherryPick : .revert
        try await beginHistoryAction(localized("\(action.title) \(targets.count) commits"), operation: operation)
        do {
            _ = try await GitProcess.run([action == .cherryPick ? "cherry-pick" : "revert", "--no-edit", "--no-walk=unsorted"]
                + (mainline.map { ["--mainline", String($0)] } ?? []) + targets, at: root, timeout: 120)
            try await finishHistoryAction()
        } catch {
            // Conflicts keep Git's sequencer and the original checkpoint for Continue
            // or Abort, including after a restart. A non-conflict failure can still
            // have completed earlier commits; retain an undo record for that progress.
            if try await currentOperation() == .none { try await finishHistoryAction() }
            throw error
        }
    }

    private func protectBatchAdditions(_ action: Integration, commit: String, parent: String?) async throws {
        let arguments: [String]
        if let parent {
            let pair = action == .cherryPick ? [parent, commit] : [commit, parent]
            arguments = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--diff-filter=A", "--name-only", "-z"] + pair + ["--"]
        } else if action == .cherryPick { arguments = ["ls-tree", "-r", "--name-only", "-z", commit, "--"] }
        else { return }
        let paths = try await GitProcess.run(arguments, at: root).data.split(separator: 0)
        for bytes in paths {
            let path = String(decoding: bytes, as: UTF8.self)
            let tracked = try await GitProcess.run(["ls-files", "--error-unmatch", "--", path], at: root, allowed: [0, 1])
            guard tracked.status != 0 else { continue }
            var url = root
            for component in path.split(separator: "/") {
                url.appendPathComponent(String(component))
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   url.path == root.appendingPathComponent(path).path || attributes[.type] as? FileAttributeType != .typeDirectory {
                    throw GitFailure("The batch would replace an untracked or ignored item at \(path). Move it aside first.")
                }
            }
        }
    }
}
