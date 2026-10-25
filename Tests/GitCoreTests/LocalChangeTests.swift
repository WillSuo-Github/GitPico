import Foundation
import Testing
@testable import GitCore

@Test func discardUnstagedPreservesIndexAndRestoresAfterReopen() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "staged\n"); try await f.git(["add", "readme.txt"])
    try f.write("readme.txt", "later\r\nno newline")
    let before = try await f.git(["show", ":readme.txt"]).data
    let plan = try await f.repo.previewDiscard(paths: ["readme.txt"], scope: .unstaged)
    let backup = try await f.repo.applyLocalChange(plan)
    #expect(try Data(contentsOf: f.url.appendingPathComponent("readme.txt")) == before)
    #expect(try await f.git(["show", ":readme.txt"]).data == before)
    let reopened = try await GitRepository.open(f.url)
    #expect(try await reopened.localChangeBackups().first?.id == backup.id)
    let journal = f.url.appendingPathComponent(".git/gitpico/local-changes/\(backup.id.uuidString).json")
    #expect((try FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try await reopened.restoreLocalChanges(backup.id)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "later\r\nno newline")
    #expect(try await f.git(["show", ":readme.txt"]).data == before)
    await #expect(throws: GitFailure.self) { try await reopened.restoreLocalChanges(backup.id) }
}

@Test func discardAllRestoresStagedRenameBinaryUntrackedAndPermissions() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["mv", "readme.txt", "renamed.txt"])
    try f.write("renamed.txt", "later edit\n")
    let name = ":(glob)* 中文\nfile.bin", bytes = Data([0, 255, 128, 13, 10, 0, 42])
    try bytes.write(to: f.url.appendingPathComponent(name))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.url.appendingPathComponent(name).path)
    let plan = try await f.repo.previewDiscard(paths: ["renamed.txt", name], scope: .allLocal)
    #expect(Set(plan.paths) == Set(["readme.txt", "renamed.txt", name]))
    let backup = try await f.repo.applyLocalChange(plan)
    #expect(try await f.repo.snapshot().changes.isEmpty)
    try await f.repo.restoreLocalChanges(backup.id)
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("readme.txt").path))
    #expect(try String(contentsOf: f.url.appendingPathComponent("renamed.txt"), encoding: .utf8) == "later edit\n")
    #expect(try Data(contentsOf: f.url.appendingPathComponent(name)) == bytes)
    #expect((try FileManager.default.attributesOfItem(atPath: f.url.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    #expect(try await f.repo.snapshot().changes.contains { $0.originalPath == "readme.txt" })
}

@Test func discardDeletedFileAndUnbornStagedAddition() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try FileManager.default.removeItem(at: f.url.appendingPathComponent("readme.txt"))
    let backup = try await f.repo.applyLocalChange(try await f.repo.previewDiscard(paths: ["readme.txt"], scope: .unstaged))
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\n")
    try await f.repo.restoreLocalChanges(backup.id)
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("readme.txt").path))
    let u = try await Fixture.make(initialCommit: false); defer { u.clean() }
    try u.write("new.txt", "initial\n"); try await u.git(["add", "."]); try u.write("new.txt", "later\n")
    let saved = try await u.repo.applyLocalChange(try await u.repo.previewDiscard(paths: ["new.txt"], scope: .allLocal))
    #expect(try await u.repo.snapshot().changes.isEmpty)
    try await u.repo.restoreLocalChanges(saved.id)
    #expect(try await u.git(["show", ":new.txt"]).text == "initial\n")
    #expect(try String(contentsOf: u.url.appendingPathComponent("new.txt"), encoding: .utf8) == "later\n")
}

@Test func staleDiscardPreviewRecoveryAndIndexLockProtectNewEdits() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "first\n")
    let stale = try await f.repo.previewDiscard(paths: ["readme.txt"], scope: .unstaged)
    try f.write("readme.txt", "second\n")
    await #expect(throws: GitFailure.self) { try await f.repo.applyLocalChange(stale) }
    let plan = try await f.repo.previewDiscard(paths: ["readme.txt"], scope: .unstaged)
    let lock = f.url.appendingPathComponent(".git/index.lock")
    try Data("external lock".utf8).write(to: lock)
    await #expect(throws: GitFailure.self) { try await f.repo.applyLocalChange(plan) }
    #expect(try String(contentsOf: lock, encoding: .utf8) == "external lock")
    try FileManager.default.removeItem(at: lock)
    let saved = try await f.repo.applyLocalChange(plan)
    try f.write("readme.txt", "new external content\n")
    await #expect(throws: GitFailure.self) { try await f.repo.restoreLocalChanges(saved.id) }
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "new external content\n")
    try f.write("readme.txt", "original\n"); try f.write("other", "index change\n"); try await f.git(["add", "other"])
    await #expect(throws: GitFailure.self) { try await f.repo.restoreLocalChanges(saved.id) }
}

@Test func discardLinesAndChunkKeepOtherChanges() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", (1...40).map { "line \($0)\n" }.joined()); try await f.git(["add", "."]); try await f.git(["commit", "-m", "Lines"])
    try f.write("readme.txt", (1...40).map { $0 == 2 ? "first edit\n" : $0 == 38 ? "second edit\n" : "line \($0)\n" }.joined())
    let change = try #require(try await f.repo.snapshot().changes.first)
    let diff = try await f.repo.diff(change, staged: false, context: 3), doc = PatchDocument(diff)
    #expect(doc.hunks.count == 2)
    let first = Set(doc.selectableLines.filter { $0.hunk == doc.hunks[0].id })
    let plan = try await f.repo.previewDiscardLines(change, renderedDiff: diff, selection: first, context: 3)
    let saved = try await f.repo.applyLocalChange(plan)
    let remaining = try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8)
    #expect(remaining.contains("line 2\n") && remaining.contains("second edit\n") && !remaining.contains("first edit"))
    try await f.repo.restoreLocalChanges(saved.id)
    let chunk = try await f.repo.previewDiscardChunk(change, renderedDiff: diff, hunkID: doc.hunks[1].id, context: 3)
    try await f.repo.applyLocalChange(chunk)
    let text = try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8)
    #expect(text.contains("first edit") && !text.contains("second edit"))
}

@Test func localRecoveryRejectsSymlinksAndUnsafePaths() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-outside-\(UUID())")
    try Data("outside".utf8).write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.removeItem(at: f.url.appendingPathComponent("readme.txt"))
    try FileManager.default.createSymbolicLink(at: f.url.appendingPathComponent("readme.txt"), withDestinationURL: outside)
    await #expect(throws: GitFailure.self) { try await f.repo.previewDiscard(paths: ["readme.txt"], scope: .allLocal) }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
    for path in ["../outside", ".git/config", "a/.GIT/config", "/tmp/file"] {
        await #expect(throws: GitFailure.self) { try await f.repo.previewDiscard(paths: [path], scope: .unstaged) }
    }
}

@Test func preparedRecoveryCanRestoreAnInterruptedMultiFileWrite() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "discard me\n"); try f.write("new.txt", "untracked content\n")
    let plan = try await f.repo.previewDiscard(paths: ["readme.txt", "new.txt"], scope: .unstaged)
    // Simulate a process exit between two durable, per-file replacements.
    let record = LocalChangeBackup(plan)
    try await f.repo.saveRecovery(record, name: "local-changes/\(record.id.uuidString).json")
    try await f.repo.writeLocalFile(try #require(plan.after.first { $0.path == "readme.txt" }))
    let reopened = try await GitRepository.open(f.url)
    try await reopened.restoreLocalChanges(record.id)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "discard me\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("new.txt"), encoding: .utf8) == "untracked content\n")
}

@Test func discardRecoveryBlocksBranchSwitchAndTracksPinnedIndexObjects() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "uncommitted index object\n"); try await f.git(["add", "."])
    let backup = try await f.repo.applyLocalChange(try await f.repo.previewDiscard(paths: ["readme.txt"], scope: .allLocal))
    let refs = try await f.git(["for-each-ref", "--format=%(refname) %(objecttype)", "refs/gitpico/local-changes/"])
    #expect(refs.text.contains("/before tree"))
    try await f.git(["checkout", "-b", "elsewhere"])
    await #expect(throws: GitFailure.self) { try await f.repo.restoreLocalChanges(backup.id) }
    try await f.git(["checkout", "main"])
    // Hidden tree refs keep the discarded index blobs reachable through GC.
    try await f.git(["gc", "--prune=now"])
    try await f.repo.restoreLocalChanges(backup.id)
    #expect(try await f.git(["show", ":readme.txt"]).text == "uncommitted index object\n")
}

@Test func discardRejectsGitlinksAndExternalParentSymlinks() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let hash = try await f.repo.headPosition().hash!
    try await f.git(["update-index", "--add", "--cacheinfo", "160000," + hash + ",module"])
    await #expect(throws: GitFailure.self) { try await f.repo.previewDiscard(paths: ["module"], scope: .allLocal) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-parent-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createSymbolicLink(at: f.url.appendingPathComponent("folder"), withDestinationURL: directory)
    let data = Data("diff --git a/folder/new.txt b/folder/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/folder/new.txt\n@@ -0,0 +1 @@\n+outside write\n".utf8)
    await #expect(throws: GitFailure.self) { try await f.repo.previewPatch(data, destination: .workingCopy) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}
