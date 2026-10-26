import Foundation
import GitCore
import Testing
@testable import GitPico

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
