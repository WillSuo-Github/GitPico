import Foundation
import GitCore

struct RebaseRequest: Identifiable {
    let id = UUID()
    var base: String?
    var preparedPlan: InteractiveRebasePlan? = nil
}

enum RecoveryAction { case undo(UndoRecord, Bool), restore(String), branch(String) }
struct RecoveryRequest: Identifiable {
    let id = UUID()
    let action: RecoveryAction
}

extension RepositoryStore {
    func prepareFixup(_ commit: Commit) {
        guard canIntegrate else { return }
        amend = false; draftBeforeAmend = nil
        // Preserve existing prose in the description instead of silently discarding a draft.
        let existing = commitSubject + (commitBody.isEmpty ? "" : "\n\n" + commitBody)
        commitSubject = "fixup! " + commit.subject
        if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { commitBody = existing }
        navigate(.workingCopy)
        commitFeedback = "Fixup message prepared. Stage the correction and commit, then use Autosquash in Interactive Rebase."
    }
    func startInteractiveRebase(_ plan: InteractiveRebasePlan) {
        protectedPerform("Interactive Rebase…") { try await $0.startInteractiveRebase(plan) }
    }

    func undoHistory(_ record: UndoRecord, redo: Bool) {
        perform(redo ? "Redoing \(record.title)…" : "Undoing \(record.title)…") { try await $0.undoHistory(expected: record.id, redo: redo) }
    }
    func restoreHistory(hash: String, expected: HeadPosition, restoreFiles: Bool) {
        perform("Restoring HEAD…") { try await $0.restoreHistory(to: hash, expected: expected, restoreFiles: restoreFiles) }
    }
    func recoverBranch(_ name: String, hash: String) { perform("Recovering branch…") { try await $0.recoverBranch(name, at: hash) } }
    func amendRebaseStop(_ message: String) { perform("Amending paused commit…") { try await $0.amendRebaseStop(message: message) } }
    func skipRebaseCommit() { perform("Skipping rebase commit…") { try await $0.skipRebaseCommit() } }
}
