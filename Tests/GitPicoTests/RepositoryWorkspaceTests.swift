import Foundation
import GitCore
import Testing
@testable import GitPico

@Test @MainActor func sleepWakeReconciliationPreservesDraftsSelectionAndExternalEdits() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let workspace = t.workspace
    await workspace.open(await t.f.repository.root)
    let store = workspace.activeStore
    store.commitSubject = "Before sleeping"; store.commitBody = "Keep this draft"
    workspace.prepareForSleep()
    try await t.f.write("a.txt", "external edit while asleep\n")
    workspace.resumeAfterWake(); await store.refreshAutomatically(); await store.detailTask?.value
    #expect(store.changes.contains { $0.path == "a.txt" })
    #expect(store.commitSubject == "Before sleeping" && store.commitBody == "Keep this draft")
    #expect(workspace.draftSaveWarning == nil && workspace.sessionSaveWarning == nil)
    let reopened = RepositoryDraftStore(file: workspace.drafts.file)
    #expect(reopened.values[store.snapshot!.root.path]?.subject == "Before sleeping")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RUN_SESSION_STRESS"] == "1", "Explicit repeated workspace/draft/refresh stress; not physical sleep or an energy soak."))
@MainActor func repeatedSessionSavesAndRefreshesKeepIndependentDrafts() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let workspace = t.workspace
    await workspace.open(await t.f.repository.root)
    let first = workspace.activeTab
    workspace.newTab(); await workspace.open(t.second)
    let second = workspace.activeTab
    for round in 0..<40 {
        first.store.commitSubject = "First \(round)"; second.store.commitSubject = "Second \(round)"
        try await t.f.write("a.txt", "round \(round)\n")
        workspace.prepareForSleep(); workspace.resumeAfterWake()
        await first.store.refreshAutomatically()
        workspace.select(round.isMultiple(of: 2) ? first.id : second.id)
        workspace.saveSession()
        #expect(workspace.draftSaveWarning == nil && workspace.sessionSaveWarning == nil)
        #expect(first.store.commitSubject == "First \(round)" && second.store.commitSubject == "Second \(round)")
        #expect(first.store.historyCache.count <= 16)
    }
    #expect(WorkspaceSessionStore(file: workspace.session.file).saved?.tabs.count == 2)
}

@Test @MainActor func workspaceSessionRestoresRepositoriesNavigationSelectionAndDrafts() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace
    await w.open(await t.f.repository.root)
    let first = w.activeTab
    first.store.commitSubject = "Restore this draft"
    first.store.navigate(.history)
    await first.store.historyTask?.value; await first.store.detailTask?.value
    let hash = first.store.selectedCommit?.hash
    w.newTab(); await w.open(t.second)
    let second = w.activeTab
    w.select(first.id); w.shutdown()
    let restored = RepositoryWorkspace(library: w.library, draftsFile: w.drafts.file)
    defer { restored.shutdown(); for tab in restored.tabs { tab.store.stopAutomaticRefresh(); tab.store.cancelPreviewWork(); tab.store.metadataTask?.cancel() } }
    await restored.restoreSavedSession()
    #expect(restored.tabs.map(\.id) == [first.id, second.id])
    #expect(restored.selectedID == first.id && restored.activeStore.destination == .history)
    #expect(restored.activeStore.selectedCommit?.hash == hash)
    #expect(restored.activeStore.commitSubject == "Restore this draft")
    #expect(restored.tabs[1].root?.path == t.second.resolvingSymlinksInPath().path)
    #expect(restored.sessionSaveWarning == nil)
}

@Test @MainActor func corruptOrExternallyChangedSessionIsNotSilentlyOverwritten() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    await t.workspace.open(await t.f.repository.root)
    t.workspace.saveSession()
    let original = try Data(contentsOf: t.workspace.session.file)
    let corrupt = Data("not a workspace".utf8)
    try corrupt.write(to: t.workspace.session.file)
    t.workspace.saveSession()
    #expect(t.workspace.sessionSaveWarning != nil)
    #expect(try Data(contentsOf: t.workspace.session.file) == corrupt)
    let reopened = RepositoryWorkspace(library: t.workspace.library)
    reopened.saveSession()
    #expect(reopened.sessionSaveWarning != nil)
    #expect(try Data(contentsOf: t.workspace.session.file) == corrupt)
    try original.write(to: t.workspace.session.file)
}

@MainActor private struct TabFixture {
    let f: WorkingAppFixture
    let second: URL
    let workspace: RepositoryWorkspace
    static func make(draftsFile: URL? = nil) async throws -> Self {
        let f = try await WorkingAppFixture.make()
        let second = f.root.appendingPathComponent("Second Repository")
        _ = try await GitRepository.create(at: second)
        let workspace = RepositoryWorkspace(library: f.store.library, draftsFile: draftsFile ?? f.root.appendingPathComponent("drafts.json"))
        return Self(f: f, second: second, workspace: workspace)
    }
    func clean() { workspace.shutdown(); for tab in workspace.tabs { tab.store.cancelPreviewWork(); tab.store.metadataTask?.cancel() }; f.clean() }
}

@Test @MainActor func repositoryVisitsIgnorePagesAndRestoreDraftsAndLatestLocation() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace, first = await t.f.repository.root
    await w.open(first)
    let store = w.activeStore
    store.commitSubject = "Keep repository A draft"
    store.navigate(.history); await store.historyTask?.value; await store.detailTask?.value
    let hash = store.selectedCommit?.hash
    store.navigate(.workingCopy); store.navigate(.history)
    await store.historyTask?.value; await store.detailTask?.value
    #expect(w.repositoryVisits.back.isEmpty && !store.canGoBack)
    await w.open(t.second)
    #expect(w.repositoryVisits.back == [first.path] && store.canGoBack)
    store.commitSubject = "Keep repository B draft"
    await w.navigateRepositories(.back, from: store)
    #expect(w.activeStore === store && w.tabs.count == 1)
    #expect(store.snapshot?.root == first && store.destination == .history)
    #expect(store.commitSubject == "Keep repository A draft" && store.selectedCommit?.hash == hash)
    #expect(!store.canGoBack && store.canGoForward)
    store.navigate(.workingCopy)
    #expect(store.canGoForward)
    await w.navigateRepositories(.forward, from: store)
    #expect(store.snapshot?.root.path == t.second.resolvingSymlinksInPath().path)
    #expect(store.commitSubject == "Keep repository B draft" && store.canGoBack && !store.canGoForward)
}

@Test @MainActor func repositoryVisitsReuseOpenTabsAndDoNotConsumeFailedOrBusyNavigation() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace, root = await t.f.repository.root
    await w.open(root)
    let first = w.activeTab
    w.newTab(); await w.open(t.second)
    let second = w.activeTab
    await w.navigateRepositories(.back, from: second.store)
    #expect(w.selectedID == first.id && w.tabs.count == 2 && w.activeStore === first.store)
    let visits = w.repositoryVisits
    first.store.isBusy = true
    await w.navigateRepositories(.forward, from: first.store)
    #expect(w.repositoryVisits == visits && w.selectedID == first.id)
    first.store.isBusy = false
    await w.open(t.f.root.appendingPathComponent("Missing Repository"))
    #expect(w.repositoryVisits == visits && w.selectedID == first.id && first.store.canGoForward)
    first.store.error = nil
    await w.navigateRepositories(.forward, from: first.store)
    #expect(w.selectedID == second.id && w.tabs.count == 2)
    w.select(first.id)
    #expect(w.repositoryVisits.current == root.path && w.repositoryVisits.back.last == t.second.resolvingSymlinksInPath().path)
}

@Test @MainActor func failedBackKeepsVisitsAndOnlySuccessfulNewRepositoriesClearForward() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace, first = await t.f.repository.root
    await w.open(t.second); await w.open(first)
    let moved = t.f.root.appendingPathComponent("Temporarily Moved")
    try FileManager.default.moveItem(at: t.second, to: moved)
    let visits = w.repositoryVisits
    await w.navigateRepositories(.back, from: w.activeStore)
    #expect(w.repositoryVisits == visits && w.activeStore.snapshot?.root == first)
    try FileManager.default.moveItem(at: moved, to: t.second)
    w.activeStore.error = nil
    await w.navigateRepositories(.back, from: w.activeStore)
    #expect(w.activeStore.canGoForward)
    await w.open(t.second)
    #expect(w.activeStore.canGoForward)
    let third = t.f.root.appendingPathComponent("Third Repository")
    _ = try await GitRepository.create(at: third)
    await w.open(third)
    #expect(!w.activeStore.canGoForward && w.repositoryVisits.current == third.resolvingSymlinksInPath().path)
}

@Test @MainActor func repositoryVisitsPersistAndOlderPageHistoryDoesNotBecomeRepositoryVisits() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace
    await w.open(await t.f.repository.root); await w.open(t.second)
    w.saveSession()
    let visits = w.repositoryVisits
    let restored = RepositoryWorkspace(library: w.library, draftsFile: w.drafts.file)
    defer { restored.shutdown() }
    await restored.restoreSavedSession()
    #expect(restored.repositoryVisits == visits && restored.activeStore.canGoBack)
    await restored.navigateRepositories(.back, from: restored.activeStore)
    #expect(restored.activeStore.snapshot?.root == (await t.f.repository.root))
    let data = try Data(contentsOf: w.session.file)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "repositoryVisits")
    var tabs = try #require(legacy["tabs"] as? [[String: Any]])
    for index in tabs.indices {
        var navigation = try #require(tabs[index]["navigation"] as? [String: Any])
        navigation["back"] = []; navigation["forward"] = []
        tabs[index]["navigation"] = navigation
    }
    legacy["tabs"] = tabs
    let decoded = try JSONDecoder().decode(WorkspaceSession.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.repositoryVisits == nil && !decoded.tabs.isEmpty)
}

@Test func repositoryVisitsDeduplicateAndBoundHistory() {
    var visits = RepositoryVisitHistory()
    for index in 0..<150 { visits.visit("/fixture/\(index)"); visits.visit("/fixture/\(index)") }
    #expect(visits.back.count == 100 && visits.current == "/fixture/149" && visits.forward.isEmpty)
    #expect(visits.back.first == "/fixture/49")
}

@Test @MainActor func repositoryTabsPreserveIndependentDraftSelectionAndWarmHistory() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace
    await w.open(await t.f.repository.root)
    let first = w.activeTab, store = first.store
    store.commitSubject = "First repository draft"; store.commitBody = "Keep this description"
    store.sidebarFilter = "main"; store.navigate(.history)
    await store.historyTask?.value; await store.detailTask?.value
    let cache = store.historyCache.count, selected = store.selectedCommit?.hash, updated = store.lastUpdated
    w.newTab(); await w.open(t.second)
    #expect(w.tabs.count == 2 && w.activeTab.id != first.id)
    w.activeStore.commitSubject = "Second repository draft"
    let second = w.activeTab
    w.select(first.id)
    #expect(w.activeStore === store && store.commitSubject == "First repository draft" && store.commitBody == "Keep this description")
    #expect(store.destination == .history && store.selectedCommit?.hash == selected && store.historyCache.count == cache && cache > 0)
    #expect(store.sidebarFilter == "main" && store.lastUpdated == updated)
    w.select(second.id); #expect(w.activeStore.commitSubject == "Second repository draft")
    w.cycle(1); #expect(w.activeTab.id == first.id)
    w.cycle(-1); #expect(w.activeTab.id == second.id)
}

@Test @MainActor func repositoryPickerReusesEmptyTabAndDuplicateRepositoryFocusesExistingTab() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace
    await w.open(await t.f.repository.root)
    let first = w.activeTab
    first.store.commitSubject = "Keep chooser draft"
    first.store.navigate(.history)
    await first.store.historyTask?.value; await first.store.detailTask?.value
    let cache = first.store.historyCache.count, selected = first.store.selectedCommit?.hash
    w.showRepositories(); let picker = w.activeTab
    w.showRepositories()
    #expect(w.activeTab.id == first.id && picker === first && w.tabs.count == 1 && first.showsRepositoryPicker)
    #expect(!first.store.canUseRepository && !first.store.canCommit)
    w.returnToRepository(from: first.store)
    #expect(!first.showsRepositoryPicker && first.store.canUseRepository)
    #expect(first.store.commitSubject == "Keep chooser draft" && first.store.historyCache.count == cache && first.store.selectedCommit?.hash == selected)
    w.showRepositories()
    await w.open(await t.f.repository.root, from: picker.store)
    #expect(w.activeTab.id == first.id && w.tabs.count == 1 && w.activeStore === first.store)
    #expect(!first.showsRepositoryPicker && first.store.historyCache.count == cache && first.store.selectedCommit?.hash == selected)
    w.showRepositories(); await w.open(t.second)
    #expect(w.tabs.count == 1 && w.selectedID == first.id && first.store.commitSubject.isEmpty)
    await w.open(await t.f.repository.root)
    #expect(w.tabs.count == 1 && first.store.commitSubject == "Keep chooser draft")
    w.newTab(); await w.open(await t.f.repository.root)
    #expect(w.tabs.count == 1 && w.selectedID == first.id)
    w.newTab(); w.newTab(); #expect(w.tabs.count == 3)
}

@Test @MainActor func concurrentCanonicalRepositoryOpenCreatesOnlyOneWorkspace() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace, source = w.activeStore, root = await t.f.repository.root
    let nested = root.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    async let first: Void = w.open(root, from: source)
    async let second: Void = w.open(nested, from: source)
    _ = await (first, second)
    #expect(w.tabs.count == 1 && w.activeTab.root == root)
    #expect(w.activeStore.snapshot?.root == root && !w.activeTab.isOpening)
    let alias = t.f.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    await w.open(alias)
    #expect(w.tabs.count == 1 && w.activeTab.root == root)
}

@Test @MainActor func closingLastRepositoryReturnsPickerAndPersistsDraftAcrossReopen() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace, root = await t.f.repository.root
    await w.open(root)
    try await t.f.write("a.txt", "Keep disk changes\n")
    w.activeStore.commitSubject = "Persist across close"; w.activeStore.commitBody = "Body"
    let id = w.selectedID
    #expect(w.close(id))
    #expect(w.tabs.count == 1 && w.activeTab.root == nil && w.activeStore.snapshot == nil)
    #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "Keep disk changes\n")
    await w.open(root)
    #expect(w.activeStore.commitSubject == "Persist across close" && w.activeStore.commitBody == "Body")
    w.shutdown()
    let reopened = RepositoryWorkspace(library: w.library, draftsFile: w.drafts.file)
    await reopened.open(root)
    #expect(reopened.activeStore.commitSubject == "Persist across close" && reopened.activeStore.commitBody == "Body")
    reopened.shutdown()
}

@Test @MainActor func busyTabCannotCloseButOtherTabsRemainAvailable() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace
    await w.open(await t.f.repository.root)
    let first = w.activeTab
    first.store.isBusy = true; first.store.activity = "Waiting for operation"
    #expect(!w.close(first.id) && w.tabs.count == 1)
    first.store.showRepositories(); await w.open(t.second)
    #expect(w.tabs.count == 1 && !first.showsRepositoryPicker && first.root != nil)
    w.error = nil
    w.newTab(); await w.open(t.second)
    #expect(w.activeTab.id != first.id && w.tabs.count == 2)
    #expect(first.store.isBusy && first.store.activity == "Waiting for operation")
    first.store.isBusy = false
    #expect(w.close(first.id) && w.tabs.count == 1)
}

@Test @MainActor func rejectedOpenKeepsExistingRepositoryAndDraftIntact() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace
    await w.open(await t.f.repository.root)
    let first = w.activeTab; first.store.commitSubject = "Keep me"
    await w.open(t.f.root.appendingPathComponent("Not a repository"))
    #expect(w.tabs.count == 1 && w.activeTab === first && w.activeStore.error != nil)
    #expect(first.store.commitSubject == "Keep me" && first.store.snapshot != nil)
    #expect(!first.showsRepositoryPicker && !first.isOpening)
}

@Test @MainActor func corruptDraftStoragePreventsSilentLossWhenClosingRepository() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let file = f.root.appendingPathComponent("bad-drafts.json")
    let original = Data("invalid JSON".utf8); try original.write(to: file)
    let w = RepositoryWorkspace(library: f.store.library, draftsFile: file)
    await w.open(await f.repository.root)
    w.activeStore.commitSubject = "Do not lose this"
    let second = f.root.appendingPathComponent("Draft Protected Replacement")
    _ = try await GitRepository.create(at: second)
    w.showRepositories(); await w.open(second)
    #expect(w.tabs.count == 1 && w.activeTab.root == f.store.snapshot?.root && w.activeStore.commitSubject == "Do not lose this")
    #expect(w.activeTab.showsRepositoryPicker && w.activeStore.error != nil)
    w.returnToRepository(from: w.activeStore)
    #expect(!w.close(w.selectedID) && w.tabs.count == 1 && w.error != nil)
    #expect(w.activeStore.commitSubject == "Do not lose this")
    #expect(try Data(contentsOf: file) == original)
    try Data("{}".utf8).write(to: file)
    w.flushDrafts()
    #expect(w.draftSaveWarning == nil && w.close(w.selectedID))
    w.shutdown()
}

@Test @MainActor func successfulCommitClearsPersistedTabDraft() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace, root = await t.f.repository.root
    await w.open(root); let store = w.activeStore
    try await t.f.write("a.txt", "Committed from tab\n")
    store.snapshot = try await t.f.repository.snapshot(); await store.rebuildWorkingList()
    store.stage(store.changes); await store.operationTask?.value
    store.commitSubject = "Commit from tab"; store.commitBody = "Clear this stored draft"
    w.flushDrafts(); #expect(w.drafts.values[root.path] != nil)
    store.commit(); await store.operationTask?.value; await store.detailTask?.value
    #expect(store.error == nil && store.commitFeedback == "Commit created.")
    #expect(w.close(w.selectedID))
    await w.open(root)
    #expect(w.activeStore.commitSubject.isEmpty && w.activeStore.commitBody.isEmpty && w.drafts.values[root.path] == nil)
}

@Test @MainActor func infrastructureReopenKeepsMovedDraftDuringSameTabReplacement() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace, original = await t.f.repository.root
    await w.open(original)
    let tab = w.activeTab; tab.store.commitSubject = "Keep migration draft"
    let moved = t.f.root.appendingPathComponent("Moved Repository")
    try FileManager.default.moveItem(at: original, to: moved)
    await tab.store.reopenCurrentRepository(moved)
    #expect(w.tabs.count == 1 && w.activeTab.id == tab.id && tab.root?.path == moved.path)
    #expect(tab.store.snapshot?.root.path == moved.path && tab.store.commitSubject == "Keep migration draft")
    let movedRoot = try #require(tab.root)
    await tab.store.reopenCurrentRepository(t.second)
    #expect(w.tabs.count == 1 && w.activeTab.id == tab.id && tab.root?.path == t.second.path)
    #expect(tab.store.commitSubject.isEmpty && w.drafts.values[movedRoot.path]?.subject == "Keep migration draft")
}

@Test @MainActor func repositoryCreationUsesCurrentTabAndRetainsReturnState() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace
    await w.open(await t.f.repository.root)
    let tab = w.activeTab
    tab.store.commitSubject = "Keep creation draft"
    w.prepareCreation(clone: false)
    #expect(w.tabs.count == 1 && w.activeTab === tab && tab.showsRepositoryPicker && tab.store.creationRequest != nil)
    tab.store.creationRequest = nil
    w.returnToRepository(from: tab.store)
    #expect(!tab.showsRepositoryPicker && tab.store.commitSubject == "Keep creation draft")
    w.prepareCreation(clone: true)
    #expect(w.tabs.count == 1 && w.activeTab === tab && tab.showsRepositoryPicker && tab.store.creationRequest != nil)
    tab.store.creationRequest = nil
}

@Test @MainActor func closedRepositorySourceCannotReplaceAnotherTab() async throws {
    let t = try await TabFixture.make(); defer { t.clean() }
    let w = t.workspace, root = await t.f.repository.root
    await w.open(root)
    let closed = w.activeTab
    w.newTab(); await w.open(t.second)
    let remaining = w.activeTab, secondRoot = remaining.root
    #expect(w.close(closed.id))
    await w.open(root, from: closed.store)
    w.showRepositories(from: closed.store)
    w.prepareCreation(clone: false, from: closed.store)
    #expect(w.tabs.count == 1 && w.activeTab === remaining && remaining.root == secondRoot)
    #expect(!remaining.showsRepositoryPicker && remaining.store.creationRequest == nil)
}
