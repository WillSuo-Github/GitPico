import Foundation
import GitCore
import Testing
@testable import GitPico

@MainActor private func treeFixture() async throws -> (WorkingAppFixture, RecordingMutationReader) {
    let f = try await WorkingAppFixture.make(), reader = RecordingMutationReader()
    let store = RepositoryStore(library: f.store.library, mutationRefreshReader: reader)
    store.repository = f.repository; store.snapshot = f.store.snapshot; store.toolPreferences = f.store.toolPreferences
    await store.rebuildWorkingList()
    return (WorkingAppFixture(root: f.root, repository: f.repository, store: store), reader)
}
@MainActor private func runGit(_ f: WorkingAppFixture, _ args: [String]) async throws {
    _ = try await GitProcess.run(args, at: f.repository.root)
}
@MainActor private func reference(_ f: WorkingAppFixture, _ name: String) throws -> Reference {
    try #require(f.store.snapshot?.references.first { $0.fullName == "refs/heads/" + name })
}

@Test @MainActor func checkoutUpdatesHeadHistoryAndBrowserWithoutManagementReload() async throws {
    let (f, reader) = try await treeFixture(); defer { f.clean() }
    try await runGit(f, ["switch", "-c", "feature"])
    try await f.write("a.txt", "feature\n"); try await f.write("feature.txt", "only on feature\n")
    try await runGit(f, ["add", "."]); try await runGit(f, ["commit", "-m", "Feature files"])
    try await runGit(f, ["switch", "main"]); try await runGit(f, ["branch", "same-tip"])
    try await f.sync(); f.store.showAllFiles = true; await f.store.refreshFileBrowser()
    f.store.navigate(.history); await f.store.historyTask?.value; await f.store.detailTask?.value
    let previous = f.store.snapshot?.head
    f.store.switchBranch(try reference(f, "same-tip")); await f.finish(); await f.store.historyTask?.value
    #expect(f.store.snapshot?.branch == "same-tip" && f.store.snapshot?.head.hash == previous?.hash)
    #expect(f.store.snapshot?.references.first(where: \.isCurrent)?.name == "same-tip")
    f.store.switchBranch(try reference(f, "feature")); await f.finish(); await f.store.historyTask?.value; await f.store.detailTask?.value
    #expect(f.store.error == nil && !f.store.isBusy)
    #expect(f.store.snapshot?.branch == "feature" && f.store.snapshot?.head.hash != previous?.hash)
    #expect(f.store.visibleWorkingFiles.contains { $0.path == "feature.txt" && $0.change == nil })
    #expect(f.store.visibleCommits.contains { $0.subject == "Feature files" })
    #expect(f.store.metadataDirty.contains(.worktrees) && f.store.metadataDirty.contains(.workflow))
    #expect(await reader.requests == [false, false])
}

@Test @MainActor func stashSaveRenamePopAndDeleteRefreshStackAndKeepStableHistory() async throws {
    let (f, reader) = try await treeFixture(); defer { f.clean() }
    f.store.navigate(.history); await f.store.historyTask?.value; await f.store.detailTask?.value
    let cacheSize = f.store.historyCache.count
    let journal = await f.repository.root.appendingPathComponent(".git/gitpico/undo.json")
    try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
    f.store.navigate(.workingCopy)
    try await f.write("a.txt", "staged work\n"); try await runGit(f, ["add", "a.txt"])
    try await f.write("b.txt", "unstaged work\n"); try await f.write("new.txt", "untracked work\n"); try await f.sync()
    var options = StashSaveOptions(); options.message = "Save all states"
    f.store.saveStash(options); await f.finish()
    #expect(f.store.error == nil && f.store.commitWarning == nil && f.store.changes.isEmpty)
    #expect(f.store.snapshot?.stashes.count == 1 && f.store.historyCache.count == cacheSize)
    f.store.navigate(.stashes)
    let original = try #require(f.store.snapshot?.stashes.first); f.store.selectStash(original)
    f.store.executeStashAction(.rename(original), name: "Renamed work"); await f.finish()
    let renamed = try #require(f.store.selectedStash)
    #expect(renamed.subject == "Renamed work" && renamed.hash != original.hash)
    f.store.executeStashAction(.apply(renamed), restoreIndex: true, deleteAfter: true); await f.finish()
    #expect(f.store.error == nil && f.store.snapshot?.stashes.isEmpty == true && f.store.selectedStash == nil)
    #expect(f.store.staged.map(\.path) == ["a.txt"])
    #expect(Set(f.store.unstaged.map(\.path)) == ["b.txt", "new.txt"])
    options.snapshot = true
    f.store.saveStash(options); await f.finish()
    #expect(f.store.staged.map(\.path) == ["a.txt"] && f.store.changes.count == 3)
    let saved = try #require(f.store.snapshot?.stashes.first)
    f.store.executeStashAction(.delete(saved)); await f.finish()
    #expect(f.store.snapshot?.stashes.isEmpty == true && f.store.changes.count == 3)
    #expect(f.store.historyCache.count == cacheSize && !f.store.metadataDirty.contains(.stashes))
    #expect(await reader.requests == Array(repeating: false, count: 5))
}

@Test @MainActor func stashBranchAndPartialFileApplyUseIncrementalState() async throws {
    let (f, reader) = try await treeFixture(); defer { f.clean() }
    try await f.write("a.txt", "saved a\n"); try await f.write("b.txt", "saved b\n"); try await f.sync()
    f.store.saveStash("Branch work"); await f.finish()
    let stash = try #require(f.store.snapshot?.stashes.first)
    f.store.executeStashAction(.files(stash, ["a.txt"])); await f.finish()
    #expect(f.store.error == nil && f.store.changes.map(\.path) == ["a.txt"] && f.store.staged.isEmpty)
    try await runGit(f, ["restore", "a.txt"]); try await f.sync()
    f.store.executeStashAction(.branch(stash), name: "from-stash"); await f.finish()
    #expect(f.store.error == nil && f.store.snapshot?.branch == "from-stash")
    #expect(f.store.snapshot?.references.first(where: \.isCurrent)?.name == "from-stash")
    #expect(f.store.snapshot?.stashes.isEmpty == true && Set(f.store.changes.map(\.path)) == ["a.txt", "b.txt"])
    #expect(await reader.requests == [false, false, false])
}

@Test @MainActor func failedStashPopPublishesConflictsAndRetainsSavedEntry() async throws {
    let (f, reader) = try await treeFixture(); defer { f.clean() }
    try await f.write("a.txt", "stashed side\n"); try await f.sync()
    f.store.saveStash("Conflicting work"); await f.finish()
    let stash = try #require(f.store.snapshot?.stashes.first)
    try await f.write("a.txt", "committed side\n")
    try await runGit(f, ["add", "a.txt"]); try await runGit(f, ["commit", "-m", "Other side"]); try await f.sync()
    f.store.navigate(.stashes); f.store.selectStash(stash)
    f.store.executeStashAction(.apply(stash), deleteAfter: true); await f.finish()
    #expect(f.store.error != nil && !f.store.isBusy && f.store.destination == .workingCopy)
    #expect(f.store.changes.first(where: { $0.path == "a.txt" })?.isConflicted == true)
    #expect(f.store.snapshot?.stashes.first?.hash == stash.hash && f.store.selectedChange == "a.txt")
    #expect(f.store.snapshot?.operation == RepositoryOperation.none)
    #expect(await reader.requests == [false, false])
}

@Test @MainActor func mergeConflictAbortAndContinueRefreshOperationAndUndo() async throws {
    let (f, reader) = try await treeFixture(); defer { f.clean() }
    try await runGit(f, ["switch", "-c", "feature"])
    try await f.write("a.txt", "feature\n"); try await runGit(f, ["add", "a.txt"]); try await runGit(f, ["commit", "-m", "Feature"])
    try await runGit(f, ["switch", "main"])
    try await f.write("a.txt", "main\n"); try await runGit(f, ["add", "a.txt"]); try await runGit(f, ["commit", "-m", "Main"])
    try await f.sync(); let original = f.store.snapshot?.head
    f.store.navigate(.history); f.store.search = "No matching commit"; await f.store.searchHistory(); await f.store.historyTask?.value
    let request = IntegrationRequest(action: .merge, revision: "feature")
    f.store.integrate(request, revision: "feature"); await f.finish()
    #expect(f.store.error != nil && f.store.snapshot?.operation == .merge && f.store.snapshot?.head == original)
    #expect(f.store.currentChange?.isConflicted == true && !f.store.isLoadingHistory)
    #expect(f.store.search.isEmpty && f.store.selectedWorkingFiles == ["a.txt"] && f.store.workingList.paths.contains("a.txt"))
    f.store.error = nil; f.store.abortOperation(); await f.finish()
    #expect(f.store.error == nil && f.store.snapshot?.operation == RepositoryOperation.none && f.store.changes.isEmpty)
    f.store.integrate(request, revision: "feature"); await f.finish()
    #expect(f.store.snapshot?.operation == .merge)
    let conflict = try await f.repository.conflict("a.txt")
    f.store.error = nil; f.store.resolveConflict(conflict, resolution: .edited("resolved\n")); await f.finish()
    #expect(f.store.error == nil && !f.store.changes.contains(where: \.isConflicted) && f.store.snapshot?.operation == .merge)
    f.store.continueOperation(); await f.finish()
    #expect(f.store.error == nil && f.store.snapshot?.operation == RepositoryOperation.none && f.store.changes.isEmpty)
    #expect(f.store.snapshot?.head != original && f.store.undoAvailability?.undo != nil)
    #expect(f.store.snapshot?.commits.first?.parents.count == 2)
    #expect(await reader.requests == [false, false, false, false, false])
}

@Test @MainActor func fastForwardAndNoOpMergeUpdateHistoryOnlyWhenHeadMoves() async throws {
    let (f, reader) = try await treeFixture(); defer { f.clean() }
    try await runGit(f, ["switch", "-c", "feature"])
    try await f.write("new.txt", "fast forward\n"); try await runGit(f, ["add", "new.txt"]); try await runGit(f, ["commit", "-m", "Fast forward"])
    try await runGit(f, ["switch", "main"]); try await f.sync()
    f.store.integrate(IntegrationRequest(action: .merge), revision: "feature"); await f.finish()
    #expect(f.store.error == nil && f.store.snapshot?.commits.first?.subject == "Fast forward")
    #expect(f.store.snapshot?.references.first(where: \.isCurrent)?.hash == f.store.snapshot?.head.hash)
    f.store.navigate(.history); await f.store.historyTask?.value; await f.store.detailTask?.value
    let pages = f.store.historyCache.count
    f.store.integrate(IntegrationRequest(action: .merge), revision: "feature"); await f.finish(); await f.store.historyTask?.value
    #expect(f.store.error == nil && f.store.historyCache.count == pages && !f.store.isBusy)
    #expect(await reader.requests == [false, false])
}

@Test @MainActor func automaticStashCarriesRefreshScopeAndRestoresStagingAfterCheckout() async throws {
    let (f, reader) = try await treeFixture(); defer { f.clean() }
    try await runGit(f, ["branch", "feature"]); try await f.sync()
    try await f.write("a.txt", "staged before checkout\n"); try await runGit(f, ["add", "a.txt"]); try await f.sync()
    let target = try reference(f, "feature")
    // Exercise the same request executor as the confirmation sheet without changing global preferences.
    let request = AutomaticStashRequest(title: "Checkout", refresh: .workingTree) { try await $0.switchBranch(target) }
    f.store.runAutomaticStash(request, message: "Restore after checkout", restoreAfter: true); await f.finish()
    #expect(f.store.error == nil && f.store.snapshot?.branch == "feature")
    #expect(f.store.automaticStash == nil && f.store.snapshot?.stashes.isEmpty == true)
    #expect(f.store.staged.map(\.path) == ["a.txt"] && f.store.unstaged.isEmpty)
    #expect(await reader.requests == [false])
}

@Test @MainActor func automaticStashWaitingBannerSurvivesMergeConflictAndAbortRestoresWork() async throws {
    let (f, reader) = try await treeFixture(); defer { f.clean() }
    try await runGit(f, ["switch", "-c", "feature"])
    try await f.write("a.txt", "feature\n"); try await runGit(f, ["add", "a.txt"]); try await runGit(f, ["commit", "-m", "Feature"])
    try await runGit(f, ["switch", "main"])
    try await f.write("a.txt", "main\n"); try await runGit(f, ["add", "a.txt"]); try await runGit(f, ["commit", "-m", "Main"])
    try await f.write("b.txt", "saved work\n"); try await runGit(f, ["add", "b.txt"]); try await f.sync()
    let request = AutomaticStashRequest(title: "Merge", refresh: .workingTree) { try await $0.integrate(.merge, revision: "feature") }
    f.store.runAutomaticStash(request, message: "Keep my work", restoreAfter: true); await f.finish()
    #expect(f.store.error != nil && f.store.snapshot?.operation == .merge)
    #expect(f.store.automaticStash?.phase == .waiting && f.store.snapshot?.stashes.count == 1)
    f.store.error = nil; f.store.abortOperation(); await f.finish()
    #expect(f.store.error == nil && f.store.snapshot?.operation == RepositoryOperation.none)
    #expect(f.store.automaticStash == nil && f.store.snapshot?.stashes.isEmpty == true)
    #expect(f.store.staged.map(\.path) == ["b.txt"] && f.store.changes.count == 1)
    #expect(await reader.requests == [false, false])
}

@Test @MainActor func checkoutRefusalRetainsLocalDiffAndUsesProtectedRequestPolicy() async throws {
    let (f, reader) = try await treeFixture(); defer { f.clean() }
    try await runGit(f, ["switch", "-c", "feature"])
    try await f.write("a.txt", "feature\n"); try await runGit(f, ["add", "a.txt"]); try await runGit(f, ["commit", "-m", "Feature"])
    try await runGit(f, ["switch", "main"]); try await f.write("a.txt", "local\n"); try await f.sync()
    f.store.setWorkingSelection(["a.txt"]); await f.store.detailTask?.value
    f.store.switchBranch(try reference(f, "feature"))
    if let request = f.store.automaticStashRequest {
        #expect(request.refresh == .workingTree)
        f.store.perform(request.title, refresh: request.refresh, action: request.action)
    }
    await f.finish()
    #expect(f.store.error != nil && !f.store.isBusy && f.store.snapshot?.branch == "main")
    #expect(f.store.selectedChange == "a.txt" && f.store.diff.contains("local"))
    #expect(await reader.requests == [false])
}

@Test @MainActor func automaticStashRestorationConflictRefreshesReviewBannerAndSavedWork() async throws {
    let (f, reader) = try await treeFixture(); defer { f.clean() }
    try await runGit(f, ["switch", "-c", "feature"])
    try await f.write("a.txt", "feature\n"); try await runGit(f, ["add", "a.txt"]); try await runGit(f, ["commit", "-m", "Feature"])
    try await runGit(f, ["switch", "main"]); try await f.write("a.txt", "saved local\n"); try await f.sync()
    let target = try reference(f, "feature")
    let request = AutomaticStashRequest(title: "Checkout", refresh: .workingTree) { try await $0.switchBranch(target) }
    f.store.runAutomaticStash(request, message: "Conflicting restoration", restoreAfter: true); await f.finish()
    #expect(f.store.error != nil && f.store.snapshot?.branch == "feature" && f.store.destination == .workingCopy)
    #expect(f.store.automaticStash?.phase == .needsReview && f.store.snapshot?.stashes.count == 1)
    #expect(!f.store.changes.isEmpty && f.store.snapshot?.operation == RepositoryOperation.none)
    #expect(await reader.requests == [false])
}

private actor FailingTreeReader: MutationRefreshReading {
    var calls = 0
    func read(_ repository: GitRepository, previous: RepositorySnapshot, history: Bool, browser: Bool, ignored: Bool, rescanIgnored: Bool, options: HistoryOptions) async throws -> IncrementalSnapshot {
        calls += 1; throw GitFailure("Injected state read failure")
    }
}
@Test @MainActor func refreshFailureKeepsOriginalWriteErrorAndDoesNotRetryFullReload() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let reader = FailingTreeReader(), store = RepositoryStore(library: f.store.library, mutationRefreshReader: reader)
    store.repository = f.repository; store.snapshot = f.store.snapshot
    store.perform("Rejected operation", refresh: .workingTree) { _ in throw GitFailure("Original write refusal") }
    await store.operationTask?.value
    #expect(!store.isBusy && store.error?.contains("Original write refusal") == true)
    #expect(store.error?.contains("Injected state read failure") == true)
    #expect(await reader.calls == 1)
}

@Test @MainActor func staleWorktreeIndicatorsDoNotBlockCheckoutButBackendStillRejectsOccupancy() async throws {
    let (f, reader) = try await treeFixture(); defer { f.clean() }
    let linked = f.root.appendingPathComponent("Linked")
    try await runGit(f, ["worktree", "add", "-b", "occupied", linked.path])
    try await f.sync()
    f.store.worktrees = try await f.repository.managedWorktrees()
    let target = try reference(f, "occupied")
    #expect(f.store.checkoutUnavailableReason(target) != nil)
    f.store.metadataDirty.insert(.worktrees)
    #expect(f.store.checkoutUnavailableReason(target) == nil)
    f.store.switchBranch(target); await f.finish()
    #expect(f.store.error != nil && f.store.snapshot?.branch == "main")
    try await runGit(f, ["worktree", "remove", linked.path])
    f.store.error = nil
    f.store.switchBranch(target); await f.finish()
    #expect(f.store.error == nil && f.store.snapshot?.branch == "occupied")
    #expect(await reader.requests == [false, false])
}
