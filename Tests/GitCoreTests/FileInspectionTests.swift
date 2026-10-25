import Foundation
import Testing
@testable import GitCore

@Test func fileInspectionFollowsRenameAndPreservesUnusualPaths() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let original = "source/old\n中文.txt", renamed = "source/new\t中文.txt"
    try f.write(original, "one\ntwo\nthree\n")
    try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Add source")
    let added = try await f.repo.snapshot().commits[0].hash
    try await f.git(["mv", "--", original, renamed]); try await f.repo.commit(message: "Rename source")
    try f.write(renamed, "one\nchanged\nthree\n")
    try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Edit source")
    var history = try await f.repo.fileHistory(path: renamed, limit: 2)
    #expect(history.hasMore && history.revisions.count == 2)
    history = try await f.repo.fileHistory(path: renamed, revision: history.tip, limit: 20)
    #expect(history.revisions.map(\.commit.subject) == ["Edit source", "Rename source", "Add source"])
    #expect(history.revisions[1].previousPath == original && history.revisions[2].path == original)
    #expect(try await f.repo.inspectedFile(path: history.revisions[2].path, revision: added) == "one\ntwo\nthree\n")
    let diff = try await f.repo.fileRevisionDiff(history.revisions[1])
    #expect(diff.contains("rename from") && diff.contains("rename to"))
    let blame = try await f.repo.blame(path: renamed)
    #expect(blame.map(\.text) == ["one", "changed", "three"])
    #expect(blame[0].hash == added && blame[0].path == original && blame[0].originalNumber == 1)
    #expect(blame[1].subject == "Edit source" && blame[1].number == 2)
    #expect(blame[0].author == "Test Author" && blame[0].email == "<test@example.invalid>")
}

@Test func fileInspectionDeletionBinaryAndLiteralPathGuards() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("literal[1].txt", "match me\n"); try f.write("literal1.txt", "unrelated\n")
    try Data([0, 255, 10]).write(to: f.url.appendingPathComponent("binary.dat"))
    try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Add files")
    try f.write("literal1.txt", "changed unrelated\n")
    try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Unrelated file")
    let history = try await f.repo.fileHistory(path: "literal[1].txt")
    #expect(history.revisions.count == 1)
    #expect(try await f.repo.inspectedFile(path: "literal[1].txt", revision: "HEAD") == "match me\n")
    await #expect(throws: GitFailure.self) { try await f.repo.blame(path: "binary.dat") }
    await #expect(throws: GitFailure.self) { try await f.repo.fileHistory(path: "../outside") }
    await #expect(throws: GitFailure.self) { try await f.repo.fileHistory(path: "/tmp/outside") }
    try await f.git(["rm", "--", "literal[1].txt"]); try await f.repo.commit(message: "Delete file")
    let deleted = try await f.repo.fileHistory(path: "literal[1].txt")
    #expect(deleted.revisions.first?.isDeleted == true && deleted.revisions.count == 2)
    #expect(try await f.repo.fileRevisionDiff(deleted.revisions[0]).contains("-match me"))
    await #expect(throws: GitFailure.self) { try await f.repo.inspectedFile(path: "literal[1].txt", revision: "HEAD") }
    await #expect(throws: GitFailure.self) { try await f.repo.historicFile(at: "HEAD", path: "literal[1].txt") }
}

@Test func blameHandlesEmptyAndUnterminatedText() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("empty.txt", ""); try f.write("tabs.txt", "\tindent\nlast without newline")
    try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Text edges")
    #expect(try await f.repo.blame(path: "empty.txt").isEmpty)
    #expect(try await f.repo.blame(path: "tabs.txt").map(\.text) == ["\tindent", "last without newline"])
}

@Test func revisionComparisonPinsSnapshotsAndUsesMergeBase() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("feature/compare")
    try f.write("feature.txt", "feature\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Feature")
    try await f.repo.switchBranch("main")
    try f.write("main.txt", "main\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Main")
    let comparison = try await f.repo.compareRevisions(left: "main", right: "feature/compare")
    #expect(Set(comparison.files.map(\.path)) == ["main.txt", "feature.txt"])
    let fromBase = try await f.repo.compareRevisions(left: "main", right: "feature/compare", useMergeBase: true)
    #expect(fromBase.files.map(\.path) == ["feature.txt"])
    try await f.repo.switchBranch("feature/compare"); try f.write("feature.txt", "changed later\n")
    try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Later")
    let diff = try await f.repo.comparisonDiff(comparison, path: "feature.txt")
    #expect(diff.contains("+feature") && !diff.contains("changed later"))
    await #expect(throws: GitFailure.self) { try await f.repo.compareRevisions(left: "--help", right: "HEAD") }
    #expect(try await f.repo.compareRevisions(left: "HEAD", right: "HEAD").files.isEmpty)
}

@Test func revisionComparisonShowsRenameWithoutArtificialDeletion() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["mv", "readme.txt", "renamed.txt"]); try await f.repo.commit(message: "Rename")
    let comparison = try await f.repo.compareRevisions(left: "HEAD~1", right: "HEAD")
    #expect(comparison.files.count == 1 && comparison.originalPaths["renamed.txt"] == "readme.txt")
    let diff = try await f.repo.comparisonDiff(comparison, path: "renamed.txt")
    #expect(diff.contains("rename from readme.txt") && diff.contains("rename to renamed.txt") && !diff.contains("new file mode"))
}

@Test func revertCreatesNewHistoryAndSupportsUndoRedo() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "updated\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Update")
    let target = try await f.repo.snapshot().commits[0].hash
    try await f.repo.integrate(.revert, revision: target)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\n")
    let result = try await f.repo.snapshot()
    #expect(result.commits.count == 3 && result.commits[0].subject == "Revert \"Update\"")
    let undo = try #require(try await f.repo.undoAvailability().undo)
    #expect(undo.title == "Revert")
    try await f.repo.undoHistory(expected: undo.id)
    #expect(try await f.repo.snapshot().commits[0].hash == target)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "updated\n")
    try await f.repo.undoHistory(expected: undo.id, redo: true)
    #expect(try await f.repo.snapshot().commits[0].hash == result.commits[0].hash)
}

@Test func revertConflictCanAbortAndContinue() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "first update\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "First update")
    let target = try await f.repo.snapshot().commits[0].hash
    try f.write("readme.txt", "second update\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Second update")
    let before = try await f.repo.snapshot().commits[0].hash
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(.revert, revision: target) }
    #expect(try await f.repo.currentOperation() == .revert)
    try await f.repo.abortOperation()
    #expect(try await f.repo.snapshot().commits[0].hash == before)
    #expect(try await f.repo.currentOperation() == .none)
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(.revert, revision: target) }
    try f.write("readme.txt", "resolved\n"); try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.continueOperation()
    #expect(try await f.repo.currentOperation() == .none)
    let record = try #require(try await f.repo.undoAvailability().undo)
    #expect(record.title == "Revert")
    try await f.repo.undoHistory(expected: record.id)
    #expect(try await f.repo.snapshot().commits[0].hash == before)
}

@Test func revertMergeRequiresExplicitMainlineAndGuardsDirtyWork() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("feature/merge-revert")
    try f.write("feature.txt", "feature\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Feature")
    try await f.repo.switchBranch("main"); try await f.git(["merge", "--no-ff", "-m", "Merge feature", "feature/merge-revert"])
    let merge = try await f.repo.snapshot().commits[0].hash
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(.revert, revision: merge) }
    try f.write("local.txt", "preserve\n")
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(.revert, revision: merge, mainline: 1) }
    try FileManager.default.removeItem(at: f.url.appendingPathComponent("local.txt"))
    try await f.repo.integrate(.revert, revision: merge, mainline: 1)
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("feature.txt").path))
    #expect(try await f.repo.snapshot().changes.isEmpty)
}

@Test func revertRejectsExternallyMovedPreviewHead() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let target = try await f.repo.snapshot().commits[0].hash
    let expected = try await f.repo.headPosition()
    try await f.git(["commit", "--allow-empty", "-m", "External commit"])
    let moved = try await f.repo.headPosition()
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(.revert, revision: target, expectedHead: expected) }
    #expect(try await f.repo.headPosition() == moved)
    #expect(try await f.repo.currentOperation() == .none)
}
