import Foundation
import Testing
@testable import GitCore

private func stashWork(_ f: Fixture) async throws -> Stash {
    try f.write("readme.txt", "staged\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try f.write("readme.txt", "working\n")
    try f.write("new[1].txt", "untracked\n")
    var options = StashSaveOptions(); options.message = "Work in progress"
    return try await f.repo.saveStash(options)
}

@Test func stashApplyRestoresExactIndexAndPopKeepsOtherEntries() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let stash = try await stashWork(f)
    #expect(try await f.repo.snapshot().changes.isEmpty)
    try f.write("other.txt", "another\n"); try await f.repo.saveStash(message: "Other")
    try await f.repo.applyStash(stash, restoreIndex: true, deleteAfter: true)
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "working\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("new[1].txt"), encoding: .utf8) == "untracked\n")
    #expect(try await f.repo.stashList().count == 1)
    #expect(try await f.repo.stashList()[0].subject.contains("Other"))
}

@Test func stashPopConflictRetainsOriginalAndCanBeResolved() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "stashed version\n"); try await f.repo.saveStash(message: "Conflicting work")
    let stash = try #require(try await f.repo.stashList().first)
    try f.write("readme.txt", "committed version\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Conflicting commit")
    await #expect(throws: GitFailure.self) { try await f.repo.applyStash(stash, restoreIndex: false, deleteAfter: true) }
    #expect(try await f.repo.stashList().count == 1)
    #expect(try await f.repo.snapshot().changes.contains(where: \.isConflicted))
    #expect(try await f.repo.currentOperation() == .none)
    try f.write("readme.txt", "resolved version\n"); try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Resolve stash")
    #expect(!(try await f.repo.snapshot().changes.contains(where: \.isConflicted)))
}

@Test func stashSnapshotAndKeepIndexPreserveStagingSemantics() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "staged\n"); try await f.repo.stage(try await f.repo.snapshot().changes)
    try f.write("readme.txt", "working\n"); try f.write("new.txt", "untracked\n")
    var options = StashSaveOptions(); options.snapshot = true; options.message = "Snapshot"
    let snapshot = try await f.repo.saveStash(options)
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "working\n")
    #expect(FileManager.default.fileExists(atPath: f.url.appendingPathComponent("new.txt").path))
    #expect(try await f.repo.stashList().first?.hash == snapshot.hash)
    options.snapshot = false; options.keepIndex = true; options.message = "Keep index"
    _ = try await f.repo.saveStash(options)
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "staged\n")
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("new.txt").path))
}

@Test func selectedFileStashingUsesLiteralPathsAndRetainsOtherWork() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("literal[1].txt", "selected\n"); try f.write("literal1.txt", "leave me\n")
    try f.write("readme.txt", "dirty tracked\n")
    var options = StashSaveOptions(); options.paths = ["literal[1].txt"]; options.message = "One file"
    let stash = try await f.repo.saveStash(options)
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("literal[1].txt").path))
    #expect(try String(contentsOf: f.url.appendingPathComponent("literal1.txt"), encoding: .utf8) == "leave me\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "dirty tracked\n")
    let detail = try await f.repo.stashDetail(stash)
    #expect(detail.files.map(\.path) == ["literal[1].txt"])
    #expect(detail.files[0].isUntracked)
    try await f.repo.applyStashFiles(stash, paths: ["literal[1].txt"])
    #expect(try String(contentsOf: f.url.appendingPathComponent("literal[1].txt"), encoding: .utf8) == "selected\n")
}

@Test func stashRenameDeleteClearAndRecoveryPreserveStoredContent() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let stash = try await stashWork(f)
    try f.write("other.txt", "other\n"); try await f.repo.saveStash(message: "Other")
    let renamed = try await f.repo.renameStash(stash, message: "New label")
    #expect(renamed.subject == "New label")
    #expect(try await f.git(["rev-parse", renamed.hash + "^{tree}"]).text == f.git(["rev-parse", stash.hash + "^{tree}"]).text)
    #expect(try await f.repo.stashList().count == 2)
    try await f.repo.deleteStash(renamed)
    let reopened = try await GitRepository.open(f.url)
    let backup = try #require(try await reopened.referenceBackups().first { $0.isStash && $0.hash == stash.hash })
    try await reopened.restoreReferenceBackup(backup, name: "Recovered work")
    let recovered = try #require(try await reopened.stashList().first)
    #expect(recovered.hash == stash.hash && recovered.subject == "Recovered work")
    let expected = try await reopened.stashList()
    try f.write("later.txt", "later\n"); try await reopened.saveStash(message: "Later")
    await #expect(throws: GitFailure.self) { try await reopened.deleteAllStashes(expected: expected) }
    try await reopened.deleteAllStashes(expected: try await reopened.stashList())
    #expect(try await reopened.stashList().isEmpty)
    try await reopened.restoreReferenceBackup(backup, name: "Restored again")
    try await reopened.applyStash(try #require(try await reopened.stashList().first), restoreIndex: true, deleteAfter: false)
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("new[1].txt"), encoding: .utf8) == "untracked\n")
}

@Test func duplicateStashHashesHaveUniqueRowsAndRejectStaleAmbiguity() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let original = try await stashWork(f)
    try f.write("middle.txt", "middle\n"); try await f.repo.saveStash(message: "Middle")
    try await f.git(["stash", "store", "-m", original.subject, original.hash])
    let list = try await f.repo.stashList()
    try #require(list.count == 3)
    #expect(Set(list.map(\.id)).count == 3)
    try f.write("extra.txt", "extra\n"); try await f.repo.saveStash(message: "Extra")
    await #expect(throws: GitFailure.self) { try await f.repo.deleteStash(list[2]) }
    #expect(try await f.repo.stashList().count == 4)
}

@Test func stashSelectedChunksAndBinaryFilesPreserveUnselectedChanges() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let original = (1...80).map { "line \($0)" }.joined(separator: "\n") + "\n"
    try f.write("chunks.txt", original)
    try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Chunks")
    try f.write("chunks.txt", original.replacingOccurrences(of: "line 3\n", with: "first change\n").replacingOccurrences(of: "line 65\n", with: "second change\n"))
    let bytes = Data([0, 255, 4, 10]); try bytes.write(to: f.url.appendingPathComponent("binary.dat"))
    try await f.repo.saveStash(message: "Chunks and binary")
    let stash = try #require(try await f.repo.stashList().first), detail = try await f.repo.stashDetail(stash)
    let file = try #require(detail.files.first { $0.path == "chunks.txt" })
    let diff = try await f.repo.stashFileDiff(stash, file: file)
    #expect(PatchDocument(diff).hunks.count == 2)
    try await f.repo.applyStashHunk(stash, file: file, renderedDiff: diff, hunkID: 0)
    let text = try String(contentsOf: f.url.appendingPathComponent("chunks.txt"), encoding: .utf8)
    #expect(text.contains("first change") && !text.contains("second change"))
    #expect(try await f.git(["show", ":chunks.txt"]).text == original)
    try await f.repo.applyStashFiles(stash, paths: ["binary.dat"])
    #expect(try Data(contentsOf: f.url.appendingPathComponent("binary.dat")) == bytes)
    #expect(try await f.repo.stashList().count == 1)
}

@Test func branchFromStashUsesOriginalBaseAndRestoresIndex() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let base = try await f.repo.headPosition().hash, stash = try await stashWork(f)
    try await f.git(["commit", "--allow-empty", "-m", "Advance main"])
    try await f.repo.branchFromStash(stash, name: "recovered/work")
    let head = try await f.repo.headPosition()
    #expect(head.branch == "refs/heads/recovered/work" && head.hash == base)
    #expect(try await f.repo.stashList().isEmpty)
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "working\n")
}
