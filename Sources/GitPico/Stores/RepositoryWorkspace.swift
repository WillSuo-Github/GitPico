import AppKit
import Foundation
import GitCore
import Observation

@MainActor protocol RepositoryWindowRouting: AnyObject {
    var hasRepositoryWindows: Bool { get }
    func prepareNewTab(from id: UUID)
    func workspaceChanged()
    func cycleNativeTabs(_ offset: Int) -> Bool
    func sessionWindows() -> [WorkspaceWindowGroup]
    func restoreWindows(_ groups: [WorkspaceWindowGroup])
}
extension RepositoryWindowRouting {
    func sessionWindows() -> [WorkspaceWindowGroup] { [] }
    func restoreWindows(_ groups: [WorkspaceWindowGroup]) {}
}

@MainActor @Observable final class RepositoryTab: Identifiable {
    let id: UUID
    let store: RepositoryStore
    var root: URL?
    var isOpening = false
    var isChoosingRepository = false
    var pickerQuery = ""
    var pickerFilter: RepositoryLibraryFilter = .recent
    var pickerSelection: UUID?
    init(store: RepositoryStore, id: UUID = UUID()) {
        self.id = id
        self.store = store
        if store.library.recentPaths.isEmpty { pickerFilter = .all }
    }
    var showsRepositoryPicker: Bool { isChoosingRepository || root == nil }
    var displayedRepositoryPath: String? {
        guard !showsRepositoryPicker, !isOpening, let root, store.snapshot?.root.path == root.path else { return nil }
        return root.path
    }
    var title: String {
        if showsRepositoryPicker { return String(localized: "Repositories") }
        if root?.path == store.snapshot?.root.path { return store.repositoryWindowTitle }
        return root.map { store.library.displayName(for: $0.path) } ?? String(localized: "Repositories")
    }
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
    var sessionSaveWarning: String?
    @ObservationIgnored let session: WorkspaceSessionStore
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored var restoringSession = false
    var repositoryVisits = RepositoryVisitHistory()
    var isNavigatingRepositories = false
    @ObservationIgnored var repositoryStates: [String: RepositorySessionState] = [:]
    @ObservationIgnored var repositoryStateOrder: [String] = []
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
        session = WorkspaceSessionStore(file: library.file.deletingLastPathComponent().appendingPathComponent("workspace-session.json"))
        let first = RepositoryTab(store: factory(library))
        tabs = [first]; selectedID = first.id; first.store.workspace = self
        draftSaveWarning = drafts.error
        sessionSaveWarning = session.error
    }
    func tab(for store: RepositoryStore) -> RepositoryTab? { tabs.first { $0.store === store } }
    func isRepositoryOpen(at path: String) -> Bool { tabs.contains { $0.displayedRepositoryPath == path } }
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
    func select(_ id: UUID, recordingVisit: Bool = true) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if selectedID != id { rememberRepositoryState(activeTab) }
        activeStore.searchFocusRequest = nil
        selectedID = id; activeStore.searchFocusRequest = nil
        if recordingVisit { recordRepositoryVisit(activeTab) }
        windowRouting?.workspaceChanged()
        scheduleSessionSave()
    }
    func cycle(_ offset: Int) {
        if windowRouting?.cycleNativeTabs(offset) == true { return }
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        select(tabs[(index + offset % tabs.count + tabs.count) % tabs.count].id)
    }
    func showRepositories(from store: RepositoryStore? = nil, recordingVisit: Bool = true) {
        guard let tab = originTab(from: store) else { return }
        guard !tab.isBusy else { error = String(localized: "Wait for this tab's repository operation before choosing another repository."); return }
        rememberRepositoryState(tab)
        tab.store.searchFocusRequest = nil
        tab.isChoosingRepository = true
        select(tab.id, recordingVisit: recordingVisit)
    }
    func returnToRepository(from store: RepositoryStore) {
        guard let tab = tab(for: store), tab.root != nil, !tab.isBusy else { return }
        tab.isChoosingRepository = false
        select(tab.id)
    }
    @discardableResult func close(_ id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let tab = tabs[index]
        guard !tab.isBusy else { error = String(localized: "Wait for this tab's repository operation to finish before closing it."); return false }
        if tab.root != nil {
            rememberRepositoryState(tab)
            do { try tab.store.flushConflictDrafts() }
            catch { self.error = String(localized: "The tab was kept open because its conflict drafts could not be saved. \(error.localizedDescription)"); return false }
            recordDraft(tab.store)
            do { try drafts.flush(); draftSaveWarning = nil }
            catch { self.error = String(localized: "The tab was kept open because its commit draft could not be saved. \(error.localizedDescription)"); return false }
        }
        tab.store.disconnectNetworkContext(); tab.store.stopAutomaticRefresh(); tab.store.cancelPreviewWork(); tab.store.metadataTask?.cancel()
        tabs.remove(at: index)
        if tabs.isEmpty { newTab() }
        else if selectedID == id { select(tabs[min(index, tabs.count - 1)].id) }
        windowRouting?.workspaceChanged()
        scheduleSessionSave()
        return true
    }
    /// True when launch will replace the initial chooser tab with saved repositories.
    var willRestoreSession: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard !didStartup, AppPreferences.shared.resumeWorkspace, !args.contains("--repository"), !args.contains("--background-testing"), !NativeStartupVerification.enabled else { return false }
        return session.saved?.tabs.contains { $0.path != nil } == true
    }
    func startup() async {
        guard !didStartup else { return }; didStartup = true
        let args = ProcessInfo.processInfo.arguments
        guard !args.contains("--background-testing"), !NativeStartupVerification.enabled else { return }
        if let index = args.firstIndex(of: "--repository"), args.indices.contains(index + 1) {
            await open(URL(fileURLWithPath: args[index + 1]), from: activeStore)
        } else if AppPreferences.shared.resumeWorkspace {
            await restoreSavedSession()
        }
    }
    func open(_ url: URL, from source: RepositoryStore? = nil, replacing: Bool = false, recordingVisit: Bool = true) async {
        guard let origin = originTab(from: source) else { return }
        if origin.isOpening { return }
        guard !origin.isBusy else { error = String(localized: "Wait for this tab's repository operation before opening another repository."); return }
        let target = origin
        rememberRepositoryState(target)
        target.isOpening = true
        select(target.id, recordingVisit: false)
        defer { target.isOpening = false; scheduleSessionSave() }
        do {
            let repository = try await GitRepository.open(url), root = await repository.root
            if let existing = tabs.first(where: { $0.id != target.id && $0.root?.path == root.path }) {
                if !existing.isOpening { existing.isChoosingRepository = false }
                select(existing.id, recordingVisit: recordingVisit)
                if target.root == nil { target.isOpening = false; _ = close(target.id) }
                return
            }
            if !replacing, target.root?.path == root.path, target.store.snapshot?.root.path == root.path {
                target.isChoosingRepository = false
                if recordingVisit, !restoringSession { repositoryVisits.visit(root.path) }
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
            if let state = repositoryStates[root.path], !replacing { await target.store.restoreSessionState(state) }
            target.isChoosingRepository = false
            if recordingVisit, selectedID == target.id, !restoringSession { repositoryVisits.visit(root.path) }
        } catch { target.store.error = error.localizedDescription }
    }
    func chooseRepository(from store: RepositoryStore) {
        guard let tab = tab(for: store), !tab.isBusy else { return }
        let panel = NSOpenPanel(); panel.title = String(localized: "Open Git Repository")
        panel.message = String(localized: "Choose a Git working directory."); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = String(localized: "Open Repository")
        panel.begin { [weak self, weak store] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in guard let self else { return }; await self.open(url, from: store) }
        }
    }
    func prepareCreation(clone: Bool, from store: RepositoryStore? = nil) {
        guard let target = originTab(from: store) else { return }
        guard !target.isBusy else { error = String(localized: "Wait for this tab's repository operation before creating a repository."); return }
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
        sessionTask?.cancel()
        saveSession()
        for tab in tabs {
            do { try tab.store.flushConflictDrafts() }
            catch { draftSaveWarning = error.localizedDescription; return }
        }
        for tab in tabs { tab.store.disconnectNetworkContext(); tab.store.stopAutomaticRefresh(); recordDraft(tab.store) }
        flushDrafts()
        networkActivity.flush()
    }
    func scheduleSessionSave() {
        guard didStartup, !restoringSession else { return }
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.saveSession()
        }
    }
    func saveSession() {
        guard !restoringSession, !tabs.contains(where: \.isOpening) else { return }
        do {
            try session.save(WorkspaceSession(tabs: tabs.map { WorkspaceSessionTab(id: $0.id, path: $0.root?.path, choosing: $0.isChoosingRepository, navigation: $0.store.sessionState) }, selected: selectedID, windows: windowRouting?.sessionWindows() ?? [], repositoryVisits: repositoryVisits))
            sessionSaveWarning = nil
        } catch { sessionSaveWarning = error.localizedDescription }
    }
    func retrySessionSave() { session.reload(); saveSession() }
    func restoreSavedSession() async {
        guard let saved = session.saved, !tabs.contains(where: \.isBusy) else { return }
        restoringSession = true
        defer { restoringSession = false; scheduleSessionSave() }
        for tab in tabs { tab.store.stopAutomaticRefresh(); tab.store.cancelPreviewWork(); tab.store.disconnectNetworkContext() }
        tabs = saved.tabs.map { item in
            let store = makeStore(library); store.workspace = self
            return RepositoryTab(store: store, id: item.id)
        }
        selectedID = saved.selected
        var failures: [String] = []
        for item in saved.tabs {
            guard let tab = tabs.first(where: { $0.id == item.id }), let path = item.path else { continue }
            await open(URL(fileURLWithPath: path), from: tab.store)
            if tab.store.snapshot != nil {
                await tab.store.restoreSessionState(item.navigation)
                tab.isChoosingRepository = item.choosing
            } else {
                tab.root = URL(fileURLWithPath: path)
                tab.isChoosingRepository = true
                tab.store.error = nil
                failures.append(path)
            }
        }
        if tabs.contains(where: { $0.id == saved.selected }) { selectedID = saved.selected }
        repositoryVisits = saved.repositoryVisits ?? RepositoryVisitHistory(current: activeTab.showsRepositoryPicker ? .library : activeTab.root.map { .repository($0.path) })
        // Older sessions could show the library while their history still pointed at a repository.
        if activeTab.showsRepositoryPicker { repositoryVisits.visit(.library) }
        windowRouting?.workspaceChanged()
        windowRouting?.restoreWindows(saved.windows)
        if !failures.isEmpty { error = String(localized: "Some saved repositories could not be reopened. Their tabs were kept for recovery:\n\(failures.joined(separator: "\n"))") }
    }
    func startMonitoring() {
        monitoringEnabled = true
        for tab in tabs where tab.root != nil { tab.store.startAutomaticRefresh() }
    }
    func refreshExternalChanges() {
        for tab in tabs where tab.root != nil { tab.store.requestAutomaticRefresh() }
    }
    func prepareForSleep() {
        var conflictErrors: [String] = []
        for tab in tabs where tab.root != nil {
            recordDraft(tab.store)
            do { try tab.store.flushConflictDrafts() }
            catch { conflictErrors.append(error.localizedDescription) }
        }
        flushDrafts(); saveSession(); networkActivity.flush()
        if !conflictErrors.isEmpty { draftSaveWarning = ([draftSaveWarning].compactMap { $0 } + conflictErrors).joined(separator: "\n") }
    }
    func resumeAfterWake() {
        for tab in tabs where tab.root != nil {
            if monitoringEnabled { tab.store.startAutomaticRefresh() }
            tab.store.requestAutomaticRefresh()
        }
    }
}
