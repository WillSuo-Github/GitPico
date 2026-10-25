import Foundation

extension GitRepository {
    func gitPicoURL(_ component: String) async throws -> URL {
        let path = try await GitProcess.run(["rev-parse", "--absolute-git-dir"], at: root).text.trimmingCharacters(in: .newlines)
        let base = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let url = base.appendingPathComponent("gitpico/" + component)
        // Internal recovery state must never follow a repository-provided symlink.
        var current = url
        while current.path.hasPrefix(base.path + "/") {
            if let type = try? FileManager.default.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType, type == .typeSymbolicLink {
                throw GitFailure("GitPico recovery storage contains a symbolic link.")
            }
            current.deleteLastPathComponent()
        }
        return url
    }

    func saveRecovery<T: Encodable>(_ value: T, name: String) async throws {
        let url = try await gitPicoURL(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    func loadRecovery<T: Decodable>(_ type: T.Type, name: String) async throws -> T? {
        let url = try await gitPicoURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    public func headPosition() async throws -> HeadPosition {
        let branch = try await GitProcess.run(["symbolic-ref", "--quiet", "HEAD"], at: root, allowed: [0, 1])
        let head = try await GitProcess.run(["rev-parse", "--verify", "--quiet", "HEAD"], at: root, allowed: [0, 1])
        return HeadPosition(branch: branch.status == 0 ? branch.text.trimmingCharacters(in: .newlines) : "HEAD", hash: head.status == 0 ? head.text.trimmingCharacters(in: .newlines) : nil)
    }

    func checkpoint(_ hash: String?, id: UUID, side: String) async throws {
        if let hash { _ = try await GitProcess.run(["update-ref", "--create-reflog", "-m", "GitPico recovery checkpoint", "refs/gitpico/checkpoints/\(id.uuidString.lowercased())/\(side)", hash], at: root) }
    }

    func recordHistory(_ before: HeadPosition, title: String, restoresFiles: Bool) async throws {
        let after = try await headPosition()
        guard before != after, before.branch == after.branch else { return }
        let record = UndoRecord(id: UUID(), title: title, before: before, after: after, restoresFiles: restoresFiles, date: Date())
        try await checkpoint(before.hash, id: record.id, side: "before")
        try await checkpoint(after.hash, id: record.id, side: "after")
        var journal = try await loadRecovery(UndoJournal.self, name: "undo.json") ?? UndoJournal()
        if let previous = journal.undo.last, previous.after != before { journal.undo = [] }
        journal.undo.append(record); journal.undo = Array(journal.undo.suffix(50)); journal.redo = []
        try await saveRecovery(journal, name: "undo.json")
    }

    func beginHistoryAction(_ title: String, operation: RepositoryOperation) async throws {
        let pending = PendingHistoryAction(before: try await headPosition(), title: title, operation: operation)
        try await checkpoint(pending.before.hash, id: UUID(), side: "before")
        try await saveRecovery(pending, name: "pending.json")
    }

    func finishHistoryAction() async throws {
        guard try await currentOperation() == .none else { return }
        if let pending = try await loadRecovery(PendingHistoryAction.self, name: "pending.json") {
            try await recordHistory(pending.before, title: pending.title, restoresFiles: true)
            try await clearPendingHistory()
        }
    }

    func clearPendingHistory() async throws {
        let url = try await gitPicoURL("pending.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func undoAvailability() async throws -> UndoAvailability {
        guard try await currentOperation() == .none else { return UndoAvailability(undo: nil, redo: nil) }
        let position = try await headPosition()
        let journal = try await loadRecovery(UndoJournal.self, name: "undo.json") ?? UndoJournal()
        return UndoAvailability(undo: journal.undo.last.flatMap { $0.after == position ? $0 : nil }, redo: journal.redo.last.flatMap { $0.before == position ? $0 : nil })
    }

    public func undoHistory(expected id: UUID, redo: Bool = false) async throws {
        guard try await currentOperation() == .none else { throw GitFailure("Finish or abort the operation before undoing history.") }
        var journal = try await loadRecovery(UndoJournal.self, name: "undo.json") ?? UndoJournal()
        guard let record = redo ? journal.redo.last : journal.undo.last, record.id == id else { throw GitFailure("The undo history changed. Refresh before continuing.") }
        let expected = redo ? record.before : record.after
        let target = redo ? record.after : record.before
        guard try await headPosition() == expected else { throw GitFailure("HEAD or the current branch changed outside GitPico. Use Reflog to inspect it.") }
        if record.restoresFiles {
            try await requireCleanHistoryWorktree()
            guard let hash = target.hash else { throw GitFailure("Cannot restore files to an unborn branch.") }
            try await protectUntrackedDestinations(hash)
            _ = try await GitProcess.run(["reset", "--keep", hash, "--"], at: root)
        } else if let hash = target.hash {
            let zero = String(repeating: "0", count: hash.count)
            _ = try await GitProcess.run(["update-ref", "-m", "GitPico: \(redo ? "redo" : "undo") \(record.title)", target.branch, hash, expected.hash ?? zero], at: root)
        } else {
            guard expected.branch != "HEAD", let hash = expected.hash else { throw GitFailure("Cannot undo the initial detached commit.") }
            _ = try await GitProcess.run(["update-ref", "-m", "GitPico: undo initial commit", "-d", target.branch, hash], at: root)
        }
        if redo { journal.redo.removeLast(); journal.undo.append(record) }
        else { journal.undo.removeLast(); journal.redo.append(record) }
        try await saveRecovery(journal, name: "undo.json")
    }

    func requireCleanHistoryWorktree() async throws {
        guard try await GitProcess.run(["status", "--porcelain=v1", "-z"], at: root).data.isEmpty else {
            throw GitFailure("Commit or stash all local changes before restoring tracked files.")
        }
    }

    public func restoreHistory(to hash: String, expected: HeadPosition, restoreFiles: Bool) async throws {
        guard try await currentOperation() == .none, try await headPosition() == expected else { throw GitFailure("Repository state changed. Reopen the restore preview.") }
        let target = try await verifiedCommit(hash)
        if restoreFiles { try await requireCleanHistoryWorktree() }
        if restoreFiles { try await protectUntrackedDestinations(target) }
        try await checkpoint(expected.hash, id: UUID(), side: "before")
        _ = try await GitProcess.run(["reset", restoreFiles ? "--keep" : "--soft", target, "--"], at: root)
        try await recordHistory(expected, title: "Restore HEAD", restoresFiles: restoreFiles)
    }

    func verifiedCommit(_ revision: String) async throws -> String {
        try await GitProcess.run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], at: root).text.trimmingCharacters(in: .newlines)
    }

    func protectUntrackedDestinations(_ target: String) async throws {
        let head = try await headPosition()
        let arguments = head.hash.map { ["diff", "--name-only", "--diff-filter=A", "-z", $0, target, "--"] }
            ?? ["ls-tree", "-r", "--name-only", "-z", target, "--"]
        let paths = try await GitProcess.run(arguments, at: root).data.split(separator: 0)
        for path in paths {
            let value = String(decoding: path, as: UTF8.self)
            let url = root.appendingPathComponent(value)
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
                throw GitFailure("Restoring history would replace an untracked or ignored item at \(value). Move it aside first.")
            }
        }
    }

    public func recoverBranch(_ name: String, at hash: String) async throws {
        guard !name.hasPrefix("-") else { throw GitFailure("Enter a valid branch name.") }
        _ = try await GitProcess.run(["check-ref-format", "--branch", name], at: root)
        let target = try await verifiedCommit(hash)
        _ = try await GitProcess.run(["branch", "--", name, target], at: root)
    }
}
