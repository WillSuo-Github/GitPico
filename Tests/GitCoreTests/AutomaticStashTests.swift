import Foundation
import Testing
@testable import GitCore

private func localDraft(_ f: Fixture) async throws {
    try f.write("readme.txt", "staged draft\n")
    try await f.git(["add", "readme.txt"])
    try f.write("readme.txt", "working draft\n")
    try f.write("draft[1].txt", "untracked draft\n")
}

@Test func automaticStashCheckoutRestoresExactIndexAndPreservesExistingStack() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("older.txt", "older saved work\n"); try await f.repo.saveStash(message: "Existing stash")
    let older = try await f.repo.stashList()
    try await f.repo.createBranch("feature", at: "HEAD", checkout: false)
    try await localDraft(f)
    try await f.repo.performWithAutomaticStash(title: "Checkout", restoreAfter: true) { try await $0.switchBranch("feature") }
    #expect(try await f.repo.headPosition().branch == "refs/heads/feature")
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged draft\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "working draft\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("draft[1].txt"), encoding: .utf8) == "untracked draft\n")
    #expect(try await f.repo.stashList().map(\.hash) == older.map(\.hash))
    #expect(try await f.repo.automaticStashRecord() == nil)
}

@Test func automaticStashFailedOperationRestoresDraftWithoutMaskingFailure() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await localDraft(f)
    await #expect(throws: GitFailure.self) {
        try await f.repo.performWithAutomaticStash(title: "Missing branch", restoreAfter: true) { try await $0.switchBranch("does-not-exist") }
    }
    #expect(try await f.repo.headPosition().branch == "refs/heads/main")
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged draft\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "working draft\n")
    #expect(try await f.repo.automaticStashRecord() == nil)
    #expect(try await f.repo.stashList().isEmpty)
}

@Test func automaticStashCanRemainSavedWithoutReapplying() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("feature", at: "HEAD", checkout: false)
    try await localDraft(f)
    try await f.repo.performWithAutomaticStash(title: "Checkout", restoreAfter: false) { try await $0.switchBranch("feature") }
    #expect(try await f.repo.snapshot().changes.isEmpty)
    #expect(try await f.repo.stashList().count == 1)
    #expect(try await f.repo.automaticStashRecord() == nil)
    try await f.repo.applyStash(try #require(try await f.repo.stashList().first), restoreIndex: true, deleteAfter: false)
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged draft\n")
}

@Test(arguments: [false, true]) func automaticStashSurvivesConflictReopenAndOperationCompletion(abort: Bool) async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("feature")
    try f.write("readme.txt", "feature committed\n"); try await f.git(["add", "."]); try await f.repo.commit(message: "Feature edit")
    try await f.repo.switchBranch("main")
    try f.write("readme.txt", "main committed\n"); try await f.git(["add", "."]); try await f.repo.commit(message: "Main edit")
    try f.write("notes.txt", "staged local notes\n"); try await f.git(["add", "notes.txt"])
    try f.write("notes.txt", "working local notes\n"); try f.write("draft.txt", "untracked\n")
    await #expect(throws: GitFailure.self) { try await f.repo.performWithAutomaticStash(title: "Merge", restoreAfter: true) { try await $0.integrate(.merge, revision: "feature") } }
    #expect(try await f.repo.currentOperation() == .merge)
    #expect(try await f.repo.automaticStashRecord()?.phase == .waiting)
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("notes.txt").path))
    let reopened = try await GitRepository.open(f.url)
    if abort { try await reopened.abortOperation() }
    else {
        try f.write("readme.txt", "resolved merge\n")
        try await f.git(["add", "readme.txt"])
        try await reopened.continueOperation()
    }
    #expect(try await reopened.currentOperation() == .none)
    #expect(try await reopened.automaticStashRecord() == nil)
    #expect(try await f.git(["show", ":notes.txt"]).text == "staged local notes\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("notes.txt"), encoding: .utf8) == "working local notes\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("draft.txt"), encoding: .utf8) == "untracked\n")
}

@Test func automaticStashRestorationFailureIsPersistentAndNeverReplayed() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("feature")
    try f.write("readme.txt", "incompatible committed\n"); try await f.git(["add", "."]); try await f.repo.commit(message: "Feature edit")
    try await f.repo.switchBranch("main")
    try f.write("readme.txt", "local draft\n"); try await f.git(["add", "readme.txt"])
    await #expect(throws: GitFailure.self) { try await f.repo.performWithAutomaticStash(title: "Checkout", restoreAfter: true) { try await $0.switchBranch("feature") } }
    let reopened = try await GitRepository.open(f.url)
    let record = try #require(try await reopened.automaticStashRecord())
    #expect(record.phase == .needsReview)
    let before = try await f.git(["status", "--porcelain=v1"]).text
    try await reopened.finishAutomaticStashIfReady()
    #expect(try await f.git(["status", "--porcelain=v1"]).text == before)
    #expect(try await reopened.stashList().contains { $0.hash == record.stashHash })
    await #expect(throws: GitFailure.self) { try await reopened.performWithAutomaticStash(title: "Another", restoreAfter: true) { _ in } }
    // This path fails before file application because --index cannot restore the old index.
    #expect(!(try await reopened.snapshot().changes.contains(where: \.isConflicted)))
    try await reopened.finishAutomaticStashReview(expected: record.id, keepSavedStash: true)
    #expect(try await reopened.automaticStashRecord() == nil)
    #expect(try await reopened.stashList().count == 1)
}

@Test func automaticStashRecoversInterruptedSaveAndProtectsNewLocalWork() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let record = AutomaticStashRecord(id: UUID(), title: "Interrupted checkout", message: "Unique recovery marker", originalHead: try await f.repo.headPosition(), phase: .saving)
    try await f.repo.saveRecovery(record, name: "automatic-stash.json")
    try f.write("saved.txt", "saved draft\n"); try await f.repo.saveStash(message: record.message)
    let reopened = try await GitRepository.open(f.url)
    #expect(try await reopened.automaticStashRecord()?.phase == .waiting)
    try f.write("later.txt", "do not overwrite\n")
    await #expect(throws: GitFailure.self) { try await reopened.finishAutomaticStashIfReady() }
    #expect(try String(contentsOf: f.url.appendingPathComponent("later.txt"), encoding: .utf8) == "do not overwrite\n")
    try await reopened.finishAutomaticStashReview(expected: record.id, keepSavedStash: true)
    #expect(try await reopened.stashList().count == 1)
}

@Test func automaticStashRejectsUnbornOrConflictedSaveWithoutStartingOperation() async throws {
    let f = try await Fixture.make(initialCommit: false); defer { f.clean() }
    try f.write("draft.txt", "keep\n")
    await #expect(throws: GitFailure.self) { try await f.repo.performWithAutomaticStash(title: "Cannot stash", restoreAfter: true) { try await $0.createBranch("should-not-exist") } }
    #expect(try String(contentsOf: f.url.appendingPathComponent("draft.txt"), encoding: .utf8) == "keep\n")
    #expect(try await f.repo.automaticStashRecord() == nil)
}

@Test func automaticStashFastForwardPullRetainsStagedAndUntrackedDrafts() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let server = f.url.deletingLastPathComponent().appendingPathComponent("Pico-auto-server-" + UUID().uuidString)
    let peer = f.url.deletingLastPathComponent().appendingPathComponent("Pico-auto-peer-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: server); try? FileManager.default.removeItem(at: peer) }
    _ = try await f.git(["init", "--bare", server.path])
    try await f.git(["remote", "add", "origin", server.path]); try await f.git(["push", "-u", "origin", "main"])
    try await f.git(["clone", "--branch", "main", server.path, peer.path])
    for (key, value) in [("user.name", "Peer"), ("user.email", "peer@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await GitProcess.run(["config", key, value], at: peer) }
    try "incoming\n".write(to: peer.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
    _ = try await GitProcess.run(["add", "."], at: peer)
    _ = try await GitProcess.run(["commit", "-m", "Incoming change"], at: peer)
    _ = try await GitProcess.run(["push"], at: peer)
    try await localDraft(f)
    try await f.repo.performWithAutomaticStash(title: "Pull", restoreAfter: true) { try await $0.sync(.pull) }
    #expect(try String(contentsOf: f.url.appendingPathComponent("remote.txt"), encoding: .utf8) == "incoming\n")
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged draft\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "working draft\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("draft[1].txt"), encoding: .utf8) == "untracked draft\n")
    #expect(try await f.repo.automaticStashRecord() == nil)
}

@Test func automaticStashWaitsThroughInteractiveRebaseEditStop() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let base = try #require(try await f.repo.headPosition().hash)
    try f.write("feature.txt", "feature\n"); try await f.git(["add", "."]); try await f.repo.commit(message: "Feature")
    var plan = try await f.repo.rebasePlan(after: base); plan.steps[0].action = .edit
    let submitted = plan
    try await localDraft(f)
    try await f.repo.performWithAutomaticStash(title: "Interactive Rebase", restoreAfter: true) { try await $0.startInteractiveRebase(submitted) }
    #expect(try await f.repo.currentOperation() == .rebase)
    #expect(try await f.repo.automaticStashRecord()?.phase == .waiting)
    let reopened = try await GitRepository.open(f.url)
    try await reopened.continueOperation()
    #expect(try await reopened.automaticStashRecord() == nil)
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged draft\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "working draft\n")
}
