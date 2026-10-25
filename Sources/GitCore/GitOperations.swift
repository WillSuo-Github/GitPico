import Foundation

extension GitRepository {
    public enum Integration: String, Sendable, CaseIterable { case merge, rebase, cherryPick, revert }

    public func integrate(_ action: Integration, revision: String, mainline: Int? = nil, expectedHead: HeadPosition? = nil) async throws {
        let status = try await GitProcess.run(["status", "--porcelain=v1", "-z"], at: root)
        guard status.data.isEmpty else { throw GitFailure("Commit or stash all local changes before \(action.rawValue).") }
        guard try await currentOperation() == .none else { throw GitFailure("Finish or abort the current operation first.") }
        let target = try await verifiedCommit(revision)
        let args: [String]
        switch action {
        case .merge: args = ["merge", "--no-edit", "--", target]
        case .rebase: args = ["rebase", "--", target]
        case .cherryPick: args = ["cherry-pick", target]
        case .revert:
            let commit = try await commit(at: target)
            if commit.parents.count > 1 {
                guard let mainline, (1...commit.parents.count).contains(mainline) else { throw GitFailure("Choose the mainline parent before reverting a merge commit.") }
            } else if mainline != nil { throw GitFailure("A mainline parent is only valid for a merge commit.") }
            args = ["revert", "--no-edit"] + (mainline.map { ["--mainline", String($0)] } ?? []) + [target]
        }
        let operation: RepositoryOperation = switch action { case .merge: .merge; case .rebase: .rebase; case .cherryPick: .cherryPick; case .revert: .revert }
        if let expectedHead, try await headPosition() != expectedHead { throw GitFailure("HEAD changed outside this preview. Reopen the operation before continuing.") }
        try await beginHistoryAction(action.rawValue.capitalized, operation: operation)
        do {
            _ = try await GitProcess.run(args, at: root, timeout: 120)
            try await finishHistoryAction()
        } catch {
            if try await currentOperation() == .none { try await clearPendingHistory() }
            throw error
        }
    }

    public func abortOperation() async throws {
        switch try await currentOperation() {
        case .none: throw GitFailure("No operation is in progress.")
        case .merge: _ = try await GitProcess.run(["merge", "--abort"], at: root)
        case .rebase: _ = try await GitProcess.run(["rebase", "--abort"], at: root)
        case .cherryPick: _ = try await GitProcess.run(["cherry-pick", "--abort"], at: root)
        case .revert: _ = try await GitProcess.run(["revert", "--abort"], at: root)
        }
        try await clearPendingHistory()
        try await finishAutomaticStashIfReady()
    }

    public func continueOperation() async throws {
        let changes = GitParser.status(try await GitProcess.run(["status", "--porcelain=v1", "-z"], at: root).data)
        guard !changes.contains(where: \.isConflicted) else { throw GitFailure("Resolve and stage all conflicts before continuing.") }
        switch try await currentOperation() {
        case .none: throw GitFailure("No operation is in progress.")
        case .merge: _ = try await GitProcess.run(["commit", "--no-edit", "--cleanup=strip"], at: root, timeout: 120)
        case .rebase: _ = try await GitProcess.run(["rebase", "--continue"], at: root, timeout: 120, acceptGeneratedMessage: true)
        case .cherryPick: _ = try await GitProcess.run(["cherry-pick", "--continue"], at: root, timeout: 120, acceptGeneratedMessage: true)
        case .revert: _ = try await GitProcess.run(["revert", "--continue"], at: root, timeout: 120, acceptGeneratedMessage: true)
        }
        try await finishHistoryAction()
        try await finishAutomaticStashIfReady()
    }
}
