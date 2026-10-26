import Foundation
import GitCore
import Testing
@testable import GitPico

@MainActor private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    try #require(condition(), "Timed out waiting for the requested repository/UI state.", sourceLocation: sourceLocation)
}

@Test @MainActor func fileEventsRefreshExternalEditsAndRefsWithoutLosingDraftOrSelection() async throws {
    let f = try await WorkingAppFixture.make()
    defer { f.store.stopAutomaticRefresh(); f.clean() }
    f.store.startAutomaticRefresh(); await f.store.automaticMonitorTask?.value
    #expect(f.store.fileMonitor?.isRunning == true)
    f.store.commitSubject = "Keep this message"
    try await f.write("a.txt", "outside edit\n")
    try await waitUntil { f.store.changes.contains { $0.path == "a.txt" } }
    // Snapshot publication precedes the detached list rebuild. A real row must exist before selecting it.
    try await waitUntil { f.store.workingList.paths.contains("a.txt") && !f.store.isLoadingWorkingFiles }
    f.store.setWorkingSelection(["a.txt"]); await f.store.detailTask?.value
    try await f.write("a.txt", "outside second edit\n")
    try await waitUntil { f.store.diff.contains("outside second edit") }
    _ = try await GitProcess.run(["branch", "external-branch"], at: f.repository.root)
    try await waitUntil { f.store.snapshot?.references.contains { $0.name == "external-branch" } == true }
    #expect(f.store.selectedChange == "a.txt" && f.store.commitSubject == "Keep this message" && !f.store.isBusy)
}

@Test @MainActor func automaticRefreshDefersDuringWritesAndRetainsWarmHistoryForFileChanges() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.store.stopAutomaticRefresh(); f.clean() }
    f.store.navigate(.history); await f.store.historyTask?.value
    let cached = f.store.historyPresentation.id
    f.store.isBusy = true
    try await f.write("a.txt", "deferred\n")
    for _ in 0..<50 { f.store.requestAutomaticRefresh() }
    await f.store.refreshAutomatically()
    #expect(f.store.changes.isEmpty && f.store.automaticRefreshPending)
    f.store.isBusy = false
    let trace = GitCommandTrace()
    await GitCommandTrace.$current.withValue(trace) { await f.store.refreshAutomatically() }
    try await waitUntil { f.store.changes.contains { $0.path == "a.txt" } }
    #expect(f.store.historyPresentation.id == cached && f.store.historyError == nil)
    #expect(await trace.samples.allSatisfy { $0.command != "log" && $0.command != "rev-list" })
}

@Test @MainActor func linkedWorktreeMonitorRefreshesSharedReferencesAndLocalFiles() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.store.stopAutomaticRefresh(); f.clean() }
    let linked = f.root.appendingPathComponent("Linked")
    _ = try await GitProcess.run(["worktree", "add", "-b", "linked", linked.path], at: f.repository.root)
    await f.store.open(linked)
    let repository = try #require(f.store.repository)
    let paths = try await repository.observationPaths()
    #expect(paths.contains(linked.path))
    #expect(paths.contains(await f.repository.root.appendingPathComponent(".git").path))
    #expect(paths.contains { $0.contains("/.git/worktrees/") })
    f.store.startAutomaticRefresh(); await f.store.automaticMonitorTask?.value
    _ = try await GitProcess.run(["branch", "shared-new-ref"], at: f.repository.root)
    try await waitUntil { f.store.snapshot?.references.contains { $0.name == "shared-new-ref" } == true }
    try Data("linked edit\n".utf8).write(to: linked.appendingPathComponent("a.txt"))
    try await waitUntil { f.store.changes.contains { $0.path == "a.txt" } }
    #expect(f.store.snapshot?.branch == "linked")
}

@Test @MainActor func backgroundFetchAllowsBrowsingAndNeverChangesWorkingFiles() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.store.stopAutomaticRefresh(); f.clean() }
    let root = await f.repository.root
    let remote = f.root.appendingPathComponent("origin.git")
    _ = try await GitProcess.run(["init", "--bare", remote.path], at: root)
    _ = try await GitProcess.run(["remote", "add", "origin", remote.path], at: root)
    _ = try await GitProcess.run(["push", "-u", "origin", "main"], at: root)
    let helper = f.root.appendingPathComponent("upload-pack.sh")
    try Data("#!/bin/sh\nsleep 0.3\nexec /usr/bin/git upload-pack \"$@\"\n".utf8).write(to: helper)
    _ = try await GitProcess.run(["config", "remote.origin.uploadpack", "/bin/sh '" + helper.path + "'"], at: root)
    try await f.write("a.txt", "keep local edit\n"); try await f.sync()
    f.store.configureNetworkContext()
    let before = try await f.repository.headPosition()
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let job = Task { await f.store.fetchInBackground() }
    try await waitUntil { f.store.isBackgroundFetching }
    f.store.navigate(.history); f.store.commitSubject = "Keep typing while fetching"
    #expect(f.store.destination == .history && !f.store.canCommit)
    await job.value
    #expect(!f.store.isBusy && !f.store.isBackgroundFetching)
    #expect(try await f.repository.headPosition() == before)
    #expect(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index)
    #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "keep local edit\n")
    #expect(f.store.commitSubject == "Keep typing while fetching")
}

@MainActor private func conflictFixture() async throws -> WorkingAppFixture {
    let f = try await WorkingAppFixture.make()
    _ = try await GitProcess.run(["switch", "-c", "conflict-source"], at: f.repository.root)
    try await f.write("a.txt", "incoming\n")
    _ = try await GitProcess.run(["add", "a.txt"], at: f.repository.root)
    _ = try await GitProcess.run(["commit", "-m", "Incoming"], at: f.repository.root)
    _ = try await GitProcess.run(["switch", "main"], at: f.repository.root)
    try await f.write("a.txt", "current\n")
    _ = try await GitProcess.run(["add", "a.txt"], at: f.repository.root)
    _ = try await GitProcess.run(["commit", "-m", "Current"], at: f.repository.root)
    _ = try await GitProcess.run(["merge", "conflict-source"], at: f.repository.root, allowed: [0,1])
    await f.store.open(f.repository.root)
    return f
}

@Test @MainActor func conflictDraftsSurviveRestartAndKeepStaleSourceGuards() async throws {
    let f = try await conflictFixture(); defer { f.clean() }
    let snapshot = try await f.repository.conflict("a.txt")
    f.store.updateConflictDraft(snapshot, text: "my unsaved resolution\n")
    try #require(f.store.conflictDraftSaveError == nil, "\(f.store.conflictDraftSaveError ?? "")")
    try f.store.flushConflictDrafts()
    let archive = try #require(f.store.conflictDraftArchive)
    let permissions = try FileManager.default.attributesOfItem(atPath: archive.file.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    let reopened = RepositoryStore(library: f.store.library)
    await reopened.open(f.repository.root)
    #expect(reopened.conflictDrafts["a.txt"]?.text == "my unsaved resolution\n")
    try await f.write("a.txt", "external resolution\n")
    let draft = try #require(reopened.conflictDrafts["a.txt"])
    await #expect(throws: GitFailure.self) { try await f.repository.resolveConflict(draft.snapshot, resolution: .edited(draft.text)) }
    _ = try await GitProcess.run(["add", "a.txt"], at: f.repository.root)
    try await reopened.reload()
    #expect(reopened.conflictDrafts["a.txt"]?.text == draft.text)
    reopened.conflictDraftSaveTask?.cancel()
}

@Test @MainActor func conflictDraftWritesRejectExternalChangesAndOlderAutosaves() async throws {
    let f = try await conflictFixture(); defer { f.clean() }
    let snapshot = try await f.repository.conflict("a.txt")
    f.store.updateConflictDraft(snapshot, text: "saved\n")
    try #require(f.store.conflictDraftSaveError == nil, "\(f.store.conflictDraftSaveError ?? "")")
    try f.store.flushConflictDrafts()
    let archive = try #require(f.store.conflictDraftArchive)
    let earlier = f.store.conflictDrafts
    f.store.updateConflictDraft(snapshot, text: "newest\n"); try f.store.flushConflictDrafts()
    try await archive.save(earlier, revision: 0)
    let reader = ConflictDraftArchive(directory: archive.file.deletingLastPathComponent(), root: await f.repository.root)
    #expect(try await reader.load()["a.txt"]?.text == "newest\n")
    try Data("external metadata".utf8).write(to: archive.file)
    #expect(throws: GitFailure.self) { try f.store.flushConflictDrafts() }
    #expect(f.store.conflictDraftSaveError != nil && f.store.conflictDrafts["a.txt"]?.text == "newest\n")
    f.store.conflictDraftSaveTask?.cancel()
}

@Test @MainActor func corruptedConflictDraftArchiveIsPreservedAndDoesNotTrapUneditedReopen() async throws {
    let f = try await conflictFixture(); defer { f.clean() }
    let archive = try #require(f.store.conflictDraftArchive)
    let original = Data("unreadable saved metadata".utf8)
    try FileManager.default.createDirectory(at: archive.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try original.write(to: archive.file)
    let reopened = RepositoryStore(library: f.store.library)
    await reopened.open(f.repository.root)
    #expect(reopened.conflictDraftSaveError != nil && reopened.conflictDrafts.isEmpty)
    try reopened.flushConflictDrafts()
    #expect(try Data(contentsOf: archive.file) == original)
    reopened.updateConflictDraft(try await f.repository.conflict("a.txt"), text: "new edits\n")
    #expect(throws: GitFailure.self) { try reopened.flushConflictDrafts() }
    #expect(try Data(contentsOf: archive.file) == original)
    reopened.conflictDraftSaveTask?.cancel()
}
