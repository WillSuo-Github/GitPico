import Foundation
import Testing
@testable import GitCore

private func batchCommit(_ f: Fixture, _ path: String, _ contents: String, _ message: String) async throws -> String {
    try f.write(path, contents)
    try await f.git(["add", "."]); try await f.git(["commit", "-m", message])
    return try await f.git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
}

@Test func batchCherryPickAndRevertPreserveReviewedOrderAndOneUndoRecord() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["checkout", "-b", "topic"])
    let a = try await batchCommit(f, "a.txt", "a\n", "Add a")
    let b = try await batchCommit(f, "b.txt", "b\n", "Add b")
    try await f.git(["checkout", "main"])
    let start = try await f.repo.headPosition()
    try await f.repo.integrateBatch(.cherryPick, revisions: [a, b], expectedHead: start)
    let messages = try await f.git(["log", "-2", "--format=%s"]).text
    #expect(messages == "Add b\nAdd a\n")
    let picked = try await f.repo.headPosition()
    let undo = try #require(try await f.repo.undoAvailability().undo)
    #expect(undo.before == start && undo.after == picked)
    try await f.repo.undoHistory(expected: undo.id)
    #expect(try await f.repo.headPosition() == start)
    let redo = try #require(try await f.repo.undoAvailability().redo)
    try await f.repo.undoHistory(expected: redo.id, redo: true)
    let hashes = try await f.git(["log", "-2", "--format=%H"]).text.split(separator: "\n").map(String.init)
    try await f.repo.integrateBatch(.revert, revisions: hashes, expectedHead: picked)
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("a.txt").path))
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("b.txt").path))
    let revertUndo = try #require(try await f.repo.undoAvailability().undo)
    #expect(revertUndo.before == picked)
    try await f.repo.undoHistory(expected: revertUndo.id)
    #expect(try await f.repo.headPosition() == picked)
}

@Test(arguments: [true, false]) func batchConflictSurvivesReopenAndCanContinueOrAbort(_ continueBatch: Bool) async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["checkout", "-b", "topic"])
    let first = try await batchCommit(f, "a.txt", "a\n", "First")
    let conflict = try await batchCommit(f, "readme.txt", "topic\n", "Conflicting second")
    let last = try await batchCommit(f, "last.txt", "last\n", "Last")
    try await f.git(["checkout", "main"])
    _ = try await batchCommit(f, "readme.txt", "main\n", "Main")
    let before = try await f.repo.headPosition()
    await #expect(throws: GitFailure.self) {
        try await f.repo.integrateBatch(.cherryPick, revisions: [first, conflict, last], expectedHead: before)
    }
    #expect(try await f.repo.currentOperation() == .cherryPick)
    let reopened = try await GitRepository.open(f.url)
    if continueBatch {
        let snapshot = try await reopened.conflict("readme.txt")
        try await reopened.resolveConflict(snapshot, resolution: .version(3))
        try await reopened.continueOperation()
        #expect(try await reopened.currentOperation() == .none)
        #expect(FileManager.default.fileExists(atPath: f.url.appendingPathComponent("last.txt").path))
        let undo = try #require(try await reopened.undoAvailability().undo)
        #expect(undo.before == before)
        try await reopened.undoHistory(expected: undo.id)
    } else { try await reopened.abortOperation() }
    #expect(try await reopened.headPosition() == before)
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("a.txt").path))
}

@Test func batchRejectsStaleHeadDuplicateCommitsAndDirtyFilesBeforeWriting() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let head = try await f.repo.headPosition(), hash = try #require(head.hash)
    await #expect(throws: GitFailure.self) { try await f.repo.integrateBatch(.revert, revisions: [hash, hash], expectedHead: head) }
    try await f.git(["commit", "--allow-empty", "-m", "External"])
    let after = try await f.repo.headPosition()
    await #expect(throws: GitFailure.self) { try await f.repo.integrateBatch(.revert, revisions: [hash], expectedHead: head) }
    try f.write("private.txt", "keep")
    await #expect(throws: GitFailure.self) { try await f.repo.integrateBatch(.revert, revisions: [hash], expectedHead: after) }
    #expect(try await f.repo.headPosition() == after)
    #expect(try String(contentsOf: f.url.appendingPathComponent("private.txt"), encoding: .utf8) == "keep")
}

@Test func batchProtectsIgnoredDestinationsBeforeAnyCommitRuns() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write(".gitignore", "*.secret\n")
    try await f.git(["add", "."]); try await f.git(["commit", "-m", "Ignore secrets"])
    try await f.git(["checkout", "-b", "topic"])
    let first = try await batchCommit(f, "a.txt", "a\n", "First")
    try f.write("private.secret", "incoming")
    try await f.git(["add", "-f", "private.secret"]); try await f.git(["commit", "-m", "Second"])
    let second = try await f.git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    try await f.git(["checkout", "main"])
    try f.write("private.secret", "local private contents")
    let before = try await f.repo.headPosition()
    await #expect(throws: GitFailure.self) { try await f.repo.integrateBatch(.cherryPick, revisions: [first, second], expectedHead: before) }
    #expect(try await f.repo.headPosition() == before)
    #expect(try String(contentsOf: f.url.appendingPathComponent("private.secret"), encoding: .utf8) == "local private contents")
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("a.txt").path))
}

@Test func batchDetectsPendingSequencerAfterConflictIsCommittedExternally() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["checkout", "-b", "topic"])
    let conflict = try await batchCommit(f, "readme.txt", "topic\n", "Conflicting step")
    let last = try await batchCommit(f, "last.txt", "last\n", "Last step")
    try await f.git(["checkout", "main"])
    _ = try await batchCommit(f, "readme.txt", "main\n", "Main")
    let before = try await f.repo.headPosition()
    await #expect(throws: GitFailure.self) { try await f.repo.integrateBatch(.cherryPick, revisions: [conflict, last], expectedHead: before) }
    try f.write("readme.txt", "resolved outside the app\n")
    try await f.git(["add", "."]); try await f.git(["commit", "--no-edit"])
    #expect(try await f.repo.currentOperation() == .cherryPick)
    try await f.repo.continueOperation()
    #expect(try await f.repo.currentOperation() == .none)
    #expect(FileManager.default.fileExists(atPath: f.url.appendingPathComponent("last.txt").path))
    #expect(try await f.repo.undoAvailability().undo?.before == before)
}

@Test(arguments: [GitRepository.Integration.cherryPick, .revert]) func batchCanSkipAnEmptyStepAndFinishRemainingCommits(_ action: GitRepository.Integration) async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["checkout", "-b", "topic"])
    let a = try await batchCommit(f, "a.txt", "a\n", "Add a")
    let b = try await batchCommit(f, "b.txt", "b\n", "Add b")
    try await f.git(["checkout", "main"])
    try await f.git(["cherry-pick", a])
    if action == .revert {
        try await f.git(["cherry-pick", b])
        try await f.git(["revert", "--no-edit", a])
    }
    let before = try await f.repo.headPosition()
    await #expect(throws: GitFailure.self) { try await f.repo.integrateBatch(action, revisions: [a, b], expectedHead: before) }
    #expect(try await f.repo.currentOperation() == (action == .cherryPick ? .cherryPick : .revert))
    try await f.repo.skipIntegrationStep()
    #expect(try await f.repo.currentOperation() == .none)
    #expect(FileManager.default.fileExists(atPath: f.url.appendingPathComponent("b.txt").path) == (action == .cherryPick))
    let undo = try #require(try await f.repo.undoAvailability().undo)
    #expect(undo.before == before)
    try await f.repo.undoHistory(expected: undo.id)
    #expect(try await f.repo.headPosition() == before)
}
