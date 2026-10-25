import Foundation
import Testing
@testable import GitCore

private func linearHistory() async throws -> Fixture {
    let f = try await Fixture.make()
    do {
        for name in ["alpha", "beta", "gamma", "delta"] {
            try f.write(name + ".txt", name + "\n")
            try await f.repo.stage(try await f.repo.snapshot().changes)
            try await f.repo.commit(message: "Add " + name)
        }
        return f
    } catch { f.clean(); throw error }
}

@Test func interactiveRebaseReordersRewordsSquashesFixesAndDrops() async throws {
    let f = try await linearHistory(); defer { f.clean() }
    let original = try await f.repo.headPosition()
    let tree = try await f.git(["rev-parse", "HEAD^{tree}"]).text
    var plan = try await f.repo.rebasePlan(after: "HEAD~4")
    plan.steps.swapAt(0, 1)
    plan.steps[0].action = .reword; plan.steps[0].message = "New beta subject\n\nMessage with `ticks` and $(literal) and 'quotes'."
    plan.steps[1].action = .squash; plan.steps[1].message = "Combined beta and alpha\n\nReviewed together."
    plan.steps[2].action = .fixup
    plan.steps[3].action = .drop
    try await f.repo.startInteractiveRebase(plan)
    #expect(try await f.repo.currentOperation() == .none)
    let snapshot = try await f.repo.snapshot()
    #expect(snapshot.commits.count == 2 && snapshot.commits[0].subject == "Combined beta and alpha")
    #expect(FileManager.default.fileExists(atPath: f.url.appendingPathComponent("gamma.txt").path))
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("delta.txt").path))
    let undo = try #require(try await f.repo.undoAvailability().undo)
    #expect(undo.title == "Interactive Rebase")
    try await f.repo.undoHistory(expected: undo.id)
    #expect(try await f.repo.headPosition() == original)
    #expect(try await f.git(["rev-parse", "HEAD^{tree}"]).text == tree)
    try await f.repo.undoHistory(expected: undo.id, redo: true)
    #expect(try await f.repo.snapshot().commits.count == 2)
    let references = try await f.git(["for-each-ref", "--format=%(objectname)", "refs/gitpico/checkpoints"])
    #expect(references.text.contains(try #require(original.hash)))
}

@Test func interactiveEditStopAmendContinueSurvivesRepositoryReopen() async throws {
    let f = try await linearHistory(); defer { f.clean() }
    let before = try await f.repo.headPosition()
    var plan = try await f.repo.rebasePlan(after: "HEAD~2")
    plan.steps[0].action = .edit
    plan.steps[1].action = .reword; plan.steps[1].message = "Final message after restart"
    try await f.repo.startInteractiveRebase(plan)
    #expect(try await f.repo.rebaseProgress()?.isEditing == true)
    #expect(try await f.repo.rebaseProgress()?.completed == 1)
    #expect(try await f.repo.rebaseProgress()?.total == 2)
    let reopened = try await GitRepository.open(f.url)
    try f.write("gamma.txt", "edited while paused\n")
    try await reopened.stage(try await reopened.snapshot().changes)
    try await reopened.amendRebaseStop(message: "Edited gamma")
    try await reopened.continueOperation()
    #expect(try await reopened.currentOperation() == .none)
    #expect(try await reopened.snapshot().commits[0].subject == "Final message after restart")
    #expect(try String(contentsOf: f.url.appendingPathComponent("gamma.txt"), encoding: .utf8) == "edited while paused\n")
    let undo = try #require(try await reopened.undoAvailability().undo)
    try await reopened.undoHistory(expected: undo.id)
    #expect(try await reopened.headPosition() == before)
}

@Test func interactiveRebaseValidatesDirtyStaleAndInvalidPlans() async throws {
    let f = try await linearHistory(); defer { f.clean() }
    var plan = try await f.repo.rebasePlan(after: "HEAD~2")
    plan.steps[0].action = .fixup
    await #expect(throws: GitFailure.self) { try await f.repo.startInteractiveRebase(plan) }
    plan.steps[0].action = .pick
    plan.steps.removeLast()
    await #expect(throws: GitFailure.self) { try await f.repo.startInteractiveRebase(plan) }
    plan = try await f.repo.rebasePlan(after: "HEAD~2")
    try f.write("untracked.txt", "do not lose\n")
    await #expect(throws: GitFailure.self) { try await f.repo.startInteractiveRebase(plan) }
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "External state change")
    await #expect(throws: GitFailure.self) { try await f.repo.startInteractiveRebase(plan) }
    #expect(try String(contentsOf: f.url.appendingPathComponent("untracked.txt"), encoding: .utf8) == "do not lose\n")
}

@Test func interactiveConflictCanAbortOrSkipAndUndo() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let base = try #require(try await f.repo.headPosition().hash)
    try await f.repo.createBranch("topic")
    try f.write("readme.txt", "topic\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Topic")
    try f.write("later.txt", "later\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Later")
    let topic = try await f.repo.headPosition()
    try await f.repo.switchBranch("main")
    try f.write("readme.txt", "main\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Main")
    let main = try #require(try await f.repo.headPosition().hash)
    try await f.repo.switchBranch("topic")
    var plan = try await f.repo.rebasePlan(after: base); plan.onto = main
    await #expect(throws: GitFailure.self) { try await f.repo.startInteractiveRebase(plan) }
    #expect(try await f.repo.rebaseProgress()?.hasConflicts == true)
    try await f.repo.abortOperation()
    #expect(try await f.repo.headPosition() == topic)
    await #expect(throws: GitFailure.self) { try await f.repo.startInteractiveRebase(plan) }
    try await f.repo.skipRebaseCommit()
    #expect(try await f.repo.currentOperation() == .none)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "main\n")
    let undo = try #require(try await f.repo.undoAvailability().undo)
    try await f.repo.undoHistory(expected: undo.id)
    #expect(try await f.repo.headPosition() == topic)
}

@Test func undoRedoCommitPreservesStagedUnstagedAndUntrackedContents() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let old = try await f.repo.headPosition()
    try f.write("readme.txt", "staged\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try f.write("readme.txt", "unstaged\n")
    try f.write("keep.txt", "untracked\n")
    try await f.repo.commit(message: "Commit staged version")
    let head = try await f.repo.headPosition()
    let record = try #require(try await f.repo.undoAvailability().undo)
    try await f.repo.undoHistory(expected: record.id)
    #expect(try await f.repo.headPosition() == old)
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "unstaged\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("keep.txt"), encoding: .utf8) == "untracked\n")
    let reopened = try await GitRepository.open(f.url)
    try await reopened.undoHistory(expected: record.id, redo: true)
    #expect(try await reopened.headPosition() == head)
    try await f.repo.commit(message: "Amended", amend: true)
    let amend = try #require(try await f.repo.undoAvailability().undo)
    #expect(amend.title == "Amend Commit")
    try await f.repo.undoHistory(expected: amend.id)
    #expect(try await f.repo.headPosition() == head)
}

@Test func initialCommitUndoAndRedoAndExternalHeadGuard() async throws {
    let f = try await Fixture.make(initialCommit: false); defer { f.clean() }
    try f.write("first.txt", "first\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Initial")
    let undo = try #require(try await f.repo.undoAvailability().undo)
    try await f.repo.undoHistory(expected: undo.id)
    #expect(try await f.repo.headPosition().hash == nil)
    #expect(try await f.repo.snapshot().changes[0].isStaged)
    try await f.repo.undoHistory(expected: undo.id, redo: true)
    _ = try await f.git(["commit", "--allow-empty", "-m", "Outside GitPico"])
    #expect(try await f.repo.undoAvailability().undo == nil)
    await #expect(throws: GitFailure.self) { try await f.repo.undoHistory(expected: undo.id) }
}

@Test func reflogUsesEventDatesAndRecoversUnreachableCommits() async throws {
    let f = try await linearHistory(); defer { f.clean() }
    let old = try #require(try await f.repo.headPosition().hash)
    let expected = try await f.repo.headPosition()
    try await f.repo.restoreHistory(to: "HEAD~2", expected: expected, restoreFiles: true)
    let events = try await f.repo.reflog()
    #expect(events.count >= 6 && events[0].date > Date().addingTimeInterval(-120))
    let entry = try #require(events.first { $0.hash == old })
    #expect(try await f.repo.commit(at: entry.hash).subject == "Add delta")
    try await f.repo.recoverBranch("recovered/delta", at: entry.hash)
    #expect(try await f.git(["rev-parse", "refs/heads/recovered/delta"]).text.trimmingCharacters(in: .newlines) == old)
    await #expect(throws: GitFailure.self) { try await f.repo.recoverBranch("recovered/delta", at: entry.hash) }
    let record = try #require(try await f.repo.undoAvailability().undo)
    try f.write("dirty.txt", "keep\n")
    await #expect(throws: GitFailure.self) { try await f.repo.undoHistory(expected: record.id) }
}

@Test func restoringHistoryNeverOverwritesIgnoredFiles() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("private.secret", "tracked version\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Track secret")
    let target = try #require(try await f.repo.headPosition().hash)
    _ = try await f.git(["rm", "private.secret"])
    try f.write(".gitignore", "*.secret\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Ignore secret")
    try f.write("private.secret", "local ignored content\n")
    #expect(try await f.repo.snapshot().changes.isEmpty)
    let expected = try await f.repo.headPosition()
    await #expect(throws: GitFailure.self) { try await f.repo.restoreHistory(to: target, expected: expected, restoreFiles: true) }
    #expect(try String(contentsOf: f.url.appendingPathComponent("private.secret"), encoding: .utf8) == "local ignored content\n")
    #expect(try await f.repo.headPosition() == expected)
}

@Test func completedConflictIntegrationCanBeUndoneAfterRestart() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("other")
    try f.write("readme.txt", "other\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Other")
    try await f.repo.switchBranch("main")
    try f.write("readme.txt", "main\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Main")
    let original = try await f.repo.headPosition()
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(.merge, revision: "other") }
    let conflict = try await f.repo.conflict("readme.txt")
    try await f.repo.resolveConflict(conflict, resolution: .edited("combined\n"))
    let reopened = try await GitRepository.open(f.url)
    try await reopened.continueOperation()
    let record = try #require(try await reopened.undoAvailability().undo)
    #expect(record.title == "Merge")
    try await reopened.undoHistory(expected: record.id)
    #expect(try await reopened.headPosition() == original)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "main\n")
    try await reopened.undoHistory(expected: record.id, redo: true)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "combined\n")
}
