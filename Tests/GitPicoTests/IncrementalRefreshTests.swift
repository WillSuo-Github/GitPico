import Foundation
import GitCore
import Testing
@testable import GitPico

actor RecordingMutationReader: MutationRefreshReading {
    var requests: [Bool] = []
    var block = false
    var waiting = false
    var continuation: CheckedContinuation<Void,Never>?
    func pause() { block = true }
    func release() { block = false; continuation?.resume(); continuation = nil }
    func read(_ repository: GitRepository, previous: RepositorySnapshot, history: Bool, browser: Bool, ignored: Bool, rescanIgnored: Bool, options: HistoryOptions) async throws -> IncrementalSnapshot {
        requests.append(history)
        let result = try await repository.incrementalSnapshot(from: previous, history: history, browser: browser, ignored: ignored, rescanIgnored: rescanIgnored, options: options)
        if block { waiting = true; await withCheckedContinuation { continuation = $0 } }
        return result
    }
}
@MainActor private func mutationFixture(_ reader: RecordingMutationReader) async throws -> WorkingAppFixture {
    let f = try await WorkingAppFixture.make()
    let store = RepositoryStore(library: f.store.library, mutationRefreshReader: reader)
    store.repository = f.repository; store.snapshot = f.store.snapshot; store.toolPreferences = f.store.toolPreferences
    await store.rebuildWorkingList()
    return WorkingAppFixture(root: f.root, repository: f.repository, store: store)
}
@Test @MainActor func indexWritesSkipUnrelatedMetadataAndPreserveWarmHistory() async throws {
    let reader = RecordingMutationReader(), f = try await mutationFixture(reader); defer { f.clean() }
    f.store.navigate(.history); await f.store.historyTask?.value; await f.store.detailTask?.value
    let pages = f.store.historyCache.count, head = f.store.snapshot?.head
    f.store.navigate(.workingCopy)
    let date = f.store.lastUpdated
    let journal = await f.repository.root.appendingPathComponent(".git/gitpico/undo.json")
    try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
    try await f.write("a.txt", "index\n"); try await f.sync()
    f.store.setWorkingSelection(["a.txt"])
    f.store.stageSelectedFiles(); await f.finish()
    #expect(f.store.error == nil && f.store.commitWarning == nil)
    #expect(f.store.historyCache.count == pages && f.store.snapshot?.head == head)
    #expect(f.store.staged.map(\.path) == ["a.txt"] && f.store.selectedChange == "a.txt")
    f.store.unstageSelectedFiles(); await f.finish()
    #expect(await reader.requests == [false,false])
    #expect(f.store.staged.isEmpty && f.store.lastUpdated != date)
    #expect(f.store.metadataDirty == [.submodules,.workflow])
}
@Test @MainActor func commitUsesBoundedRefreshAndDefersRelatedMetadataUntilRequested() async throws {
    let reader = RecordingMutationReader(), f = try await mutationFixture(reader); defer { f.clean() }
    try await f.write("a.txt", "commit\n"); try await f.sync()
    f.store.setWorkingSelection(["a.txt"]); f.store.stageSelectedFiles(); await f.finish()
    f.store.commitSubject = "Incremental commit"; f.store.commit(); await f.finish()
    #expect(await reader.requests == [false,true])
    #expect(f.store.snapshot?.commits.first?.subject == "Incremental commit" && f.store.undoAvailability?.undo != nil)
    #expect(f.store.snapshot?.head.hash == f.store.snapshot?.references.first(where: \.isCurrent)?.hash)
    #expect(f.store.metadataDirty.contains(.worktrees) && f.store.metadataDirty.contains(.submodules))
    f.store.navigate(.worktrees); await f.store.metadataTask?.value
    #expect(!f.store.metadataDirty.contains(.worktrees) && f.store.metadataDirty.contains(.submodules))
    #expect(f.store.worktrees.first(where: \.isMain)?.head == f.store.snapshot?.head.hash)
    f.store.navigate(.stashes); await f.store.metadataTask?.value
    #expect(!f.store.metadataDirty.contains(.stashes))
}
@Test @MainActor func failedIndexWriteStillUsesIncrementalRefreshAndPreservesState() async throws {
    let reader = RecordingMutationReader(), f = try await mutationFixture(reader); defer { f.clean() }
    try await f.write("a.txt", "not staged\n"); try await f.sync()
    f.store.setWorkingSelection(["a.txt"])
    let lock = await f.repository.root.appendingPathComponent(".git/index.lock")
    try Data("owned by test".utf8).write(to: lock)
    f.store.stageSelectedFiles(); await f.finish()
    #expect(f.store.error != nil && !f.store.isBusy)
    #expect(f.store.currentChange?.isUnstaged == true && f.store.staged.isEmpty)
    #expect(try String(contentsOf: lock, encoding: .utf8) == "owned by test")
    #expect(await reader.requests == [false])
}
@Test @MainActor func incrementalRefreshRejectsLateResultFromOldRepositorySession() async throws {
    let reader = RecordingMutationReader(), f = try await mutationFixture(reader); defer { f.clean() }
    try await f.write("a.txt", "edit\n"); try await f.sync()
    await reader.pause()
    let task = Task { try await f.store.reloadIncrementally(history: false) }
    let deadline = Date().addingTimeInterval(5)
    while !(await reader.waiting) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await reader.waiting)
    f.store.repositoryToken = UUID(); f.store.snapshot = nil
    await reader.release(); try await task.value
    #expect(f.store.snapshot == nil && f.store.metadataDirty.isEmpty)
}

@Test @MainActor func deferredMetadataFailureDoesNotBlockIndependentRemotes() async throws {
    let reader = RecordingMutationReader(), f = try await mutationFixture(reader); defer { f.clean() }
    let url = await f.repository.root
    _ = try await GitProcess.run(["remote", "add", "local", url.path], at: url)
    let flow = url.appendingPathComponent(".git/gitpico/management/flow")
    try FileManager.default.createDirectory(at: flow, withIntermediateDirectories: true)
    try Data("invalid json".utf8).write(to: flow.appendingPathComponent("active.json"))
    f.store.metadataDirty = [.workflow,.remotes]
    await f.store.refreshDeferredMetadata([.workflow,.remotes])
    #expect(f.store.workflowError != nil && f.store.metadataDirty.contains(.workflow))
    #expect(f.store.managedRemotes.first?.name == "local" && f.store.snapshot?.remotes == ["local"])
    #expect(!f.store.metadataDirty.contains(.remotes))
    f.store.manageFlow(.configure); await f.store.metadataTask?.value
    #expect(f.store.flowRequest == nil && f.store.error != nil)
}

@Test @MainActor func reviewedForceAddUsesIndexRefreshAndUpdatesIgnoredBrowser() async throws {
    let reader = RecordingMutationReader(), f = try await mutationFixture(reader); defer { f.clean() }
    try await f.write(".gitignore", "*.log\n"); try await f.write("private.log", "reviewed\n")
    try await f.sync(); f.store.showIgnoredFiles = true; await f.store.refreshFileBrowser()
    f.store.localChange(.forceAdd(["private.log"]))
    let request = try #require(f.store.localChangeRequest)
    let plan = try await f.repository.previewForceAddIgnored(["private.log"])
    f.store.applyLocalPlan(plan, request: request); await f.finish()
    #expect(f.store.error == nil)
    #expect(await reader.requests == [false])
    #expect(f.store.visibleWorkingFiles.contains { $0.path == "private.log" && $0.isTracked && !$0.isIgnored && $0.change?.isStaged == true })
}
