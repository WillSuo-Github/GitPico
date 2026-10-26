import AppKit
import Foundation
import GitCore
import Observation

@MainActor protocol RepositoryWindowRouting: AnyObject {
    var hasRepositoryWindows: Bool { get }
    func prepareNewTab(from id: UUID)
    func workspaceChanged()
    func cycleNativeTabs(_ offset: Int) -> Bool
}

@MainActor @Observable final class RepositoryTab: Identifiable {
    let id = UUID()
    let store: RepositoryStore
    var root: URL?
    var isOpening = false
    var isChoosingRepository = false
    var pickerQuery = ""
    var pickerFilter: RepositoryLibraryFilter = .recent
    var pickerSelection: UUID?
    init(store: RepositoryStore) {
        self.store = store
        if store.library.recentPaths.isEmpty { pickerFilter = .all }
    }
    var showsRepositoryPicker: Bool { isChoosingRepository || root == nil }
    var title: String { showsRepositoryPicker ? "Repositories" : (root.map { store.library.displayName(for: $0.path) } ?? "Repositories") }
    var isBusy: Bool { isOpening || store.isBusy }
}

@MainActor @Observable final class RepositoryWorkspace {
    private(set) var tabs: [RepositoryTab]
    private(set) var selectedID: UUID
    let library: RepositoryLibrary
    let authentication: AuthenticationStore
    let networkActivity: NetworkActivityStore
    var error: String?
    var draftSaveWarning: String?
    @ObservationIgnored let drafts: RepositoryDraftStore
    @ObservationIgnored private let makeStore: (RepositoryLibrary) -> RepositoryStore
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var didStartup = false
    @ObservationIgnored private(set) var monitoringEnabled = false
    @ObservationIgnored weak var windowRouting: (any RepositoryWindowRouting)?
    var activeTab: RepositoryTab { tabs.first { $0.id == selectedID } ?? tabs[0] }
    var activeStore: RepositoryStore { activeTab.store }
    var canCloseActiveTab: Bool { !activeTab.isBusy }

    init(library: RepositoryLibrary? = nil, draftsFile: URL? = nil, storeFactory: ((RepositoryLibrary) -> RepositoryStore)? = nil) {
        let library = library ?? RepositoryLibrary()
        self.library = library
        let authentication = AuthenticationStore(file: library.file.deletingLastPathComponent().appendingPathComponent("authentication.json"))
        self.authentication = authentication
        let networkActivity = NetworkActivityStore(directory: library.file.deletingLastPathComponent())
        self.networkActivity = networkActivity
        let factory = storeFactory ?? { RepositoryStore(library: $0, authentication: authentication, networkActivity: networkActivity) }
        self.makeStore = factory
        drafts = RepositoryDraftStore(file: draftsFile ?? library.file.deletingLastPathComponent().appendingPathComponent("repository-drafts.json"))
        let first = RepositoryTab(store: factory(library))
        tabs = [first]; selectedID = first.id; first.store.workspace = self
        draftSaveWarning = drafts.error
    }
    func tab(for store: RepositoryStore) -> RepositoryTab? { tabs.first { $0.store === store } }
    private func originTab(from store: RepositoryStore?) -> RepositoryTab? {
        if let store { return tab(for: store) }
        return activeTab
    }
    @discardableResult func newTab(from sourceID: UUID? = nil) -> RepositoryTab {
        windowRouting?.prepareNewTab(from: sourceID ?? selectedID)
        let store = makeStore(library)
        if let previous = tabs.first(where: { $0.id == selectedID }) ?? tabs.first { store.toolPreferences = previous.store.toolPreferences }
        store.workspace = self
        let tab = RepositoryTab(store: store); tabs.append(tab); select(tab.id)
        return tab
    }
    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeStore.searchFocusRequest = nil
        selectedID = id; activeStore.searchFocusRequest = nil
        windowRouting?.workspaceChanged()
    }
    func cycle(_ offset: Int) {
        if windowRouting?.cycleNativeTabs(offset) == true { return }
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        select(tabs[(index + offset % tabs.count + tabs.count) % tabs.count].id)
    }
    func showRepositories(from store: RepositoryStore? = nil) {
        guard let tab = originTab(from: store) else { return }
        guard !tab.isBusy else { error = "Wait for this tab's repository operation before choosing another repository."; return }
        tab.store.searchFocusRequest = nil
        tab.isChoosingRepository = true
        select(tab.id)
    }
    func returnToRepository(from store: RepositoryStore) {
        guard let tab = tab(for: store), tab.root != nil, !tab.isBusy else { return }
        tab.isChoosingRepository = false
        select(tab.id)
    }
    @discardableResult func close(_ id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let tab = tabs[index]
        guard !tab.isBusy else { error = "Wait for this tab's repository operation to finish before closing it."; return false }
        if tab.root != nil {
            do { try tab.store.flushConflictDrafts() }
            catch { self.error = "The tab was kept open because its conflict drafts could not be saved. " + error.localizedDescription; return false }
            recordDraft(tab.store)
            do { try drafts.flush(); draftSaveWarning = nil }
            catch { self.error = "The tab was kept open because its commit draft could not be saved. " + error.localizedDescription; return false }
        }
        tab.store.disconnectNetworkContext(); tab.store.stopAutomaticRefresh(); tab.store.cancelPreviewWork(); tab.store.metadataTask?.cancel()
        tabs.remove(at: index)
        if tabs.isEmpty { newTab() }
        else if selectedID == id { select(tabs[min(index, tabs.count - 1)].id) }
        windowRouting?.workspaceChanged()
        return true
    }
    func startup() async {
        guard !didStartup else { return }; didStartup = true
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--repository"), args.indices.contains(index + 1) {
            await open(URL(fileURLWithPath: args[index + 1]), from: activeStore)
        }
    }
    func open(_ url: URL, from source: RepositoryStore? = nil, replacing: Bool = false) async {
        guard let origin = originTab(from: source) else { return }
        if origin.isOpening { return }
        guard !origin.isBusy else { error = "Wait for this tab's repository operation before opening another repository."; return }
        let target = origin
        select(target.id)
        target.isOpening = true
        defer { target.isOpening = false }
        do {
            let repository = try await GitRepository.open(url), root = await repository.root
            if let existing = tabs.first(where: { $0.id != target.id && $0.root?.path == root.path }) {
                if !existing.isOpening { existing.isChoosingRepository = false }
                select(existing.id)
                if target.root == nil { target.isOpening = false; _ = close(target.id) }
                return
            }
            if !replacing, target.root?.path == root.path, target.store.snapshot?.root.path == root.path {
                target.isChoosingRepository = false
                return
            }
            if let previous = target.root {
                drafts.update(path: previous.path, subject: target.store.commitSubject, body: target.store.commitBody)
                do { try drafts.flush(); draftSaveWarning = nil }
                catch { draftSaveWarning = error.localizedDescription; throw error }
            }
            let saved = drafts.values[root.path] ?? (replacing ? target.root.flatMap { drafts.values[$0.path] } : nil)
            target.root = root
            await target.store.openInPlace(root, openedRepository: repository)
            if target.store.snapshot?.root.path != root.path { target.root = target.store.snapshot?.root; return }
            if let saved { target.store.commitSubject = saved.subject; target.store.commitBody = saved.body }
            target.isChoosingRepository = false
        } catch { target.store.error = error.localizedDescription }
    }
    func chooseRepository(from store: RepositoryStore) {
        guard let tab = tab(for: store), !tab.isBusy else { return }
        let panel = NSOpenPanel(); panel.title = "Open Git Repository"
        panel.message = "Choose a Git working directory."; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Open Repository"
        panel.begin { [weak self, weak store] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in guard let self else { return }; await self.open(url, from: store) }
        }
    }
    func prepareCreation(clone: Bool, from store: RepositoryStore? = nil) {
        guard let target = originTab(from: store) else { return }
        guard !target.isBusy else { error = "Wait for this tab's repository operation before creating a repository."; return }
        showRepositories(from: target.store)
        target.store.creationRequest = RepositoryCreationRequest(clone: clone)
    }
    func recordDraft(_ store: RepositoryStore) {
        guard let tab = tab(for: store), !tab.isOpening, let root = tab.root else { return }
        drafts.update(path: root.path, subject: store.commitSubject, body: store.commitBody)
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.flushDrafts()
        }
    }
    func flushDrafts() {
        draftTask?.cancel()
        do { try drafts.flush(); draftSaveWarning = nil }
        catch { draftSaveWarning = error.localizedDescription }
    }
    func shutdown() {
        for tab in tabs {
            do { try tab.store.flushConflictDrafts() }
            catch { draftSaveWarning = error.localizedDescription; return }
        }
        for tab in tabs { tab.store.disconnectNetworkContext(); tab.store.stopAutomaticRefresh(); recordDraft(tab.store) }
        flushDrafts()
        networkActivity.flush()
    }
    func startMonitoring() {
        monitoringEnabled = true
        for tab in tabs where tab.root != nil { tab.store.startAutomaticRefresh() }
    }
    func refreshExternalChanges() {
        for tab in tabs where tab.root != nil { tab.store.requestAutomaticRefresh() }
    }
}
