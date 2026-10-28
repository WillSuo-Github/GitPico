import Foundation
import GitCore
import Observation

protocol ToolbarSearchReading: Sendable {
    func files(in repository: GitRepository, includeIgnored: Bool) async throws -> [WorkingFileEntry]
    func commit(_ revision: String, in repository: GitRepository) async throws -> Commit
}
struct GitToolbarSearchReader: ToolbarSearchReading {
    func files(in repository: GitRepository, includeIgnored: Bool) async throws -> [WorkingFileEntry] { try await repository.workingFiles(includeIgnored: includeIgnored) }
    func commit(_ revision: String, in repository: GitRepository) async throws -> Commit { try await repository.commit(at: revision) }
}

struct ToolbarSearchPresentation {
    let visible: Bool
    let contextTitle: String?
    let results: [QuickActionItem]
    let selection: String?
    let loading: Bool
    let failure: String?
    let executing: Bool
    var height: CGFloat { CGFloat(min(8, results.count) + (contextTitle == nil ? 0 : 1)) * 48 + (failure == nil ? 58 : 90) }
}

@MainActor @Observable final class ToolbarSearchSession {
    let store: RepositoryStore
    private(set) var text: String
    private(set) var results: [QuickActionItem] = []
    private(set) var selection: String?
    private(set) var focused = false
    private(set) var visible = false
    private(set) var loading = false
    private(set) var searching = false
    private(set) var failure: String?
    private(set) var submitted = false
    @ObservationIgnored private let reader: any ToolbarSearchReading
    @ObservationIgnored private var baseItems: [QuickActionItem] = []
    @ObservationIgnored private var fileItems: [QuickActionItem] = []
    @ObservationIgnored private var resultsToken: UUID
    @ObservationIgnored private var queryGeneration = UUID()
    @ObservationIgnored private var indexGeneration = UUID()
    @ObservationIgnored private var loadedKey: IndexKey?
    @ObservationIgnored private var loadingKey: IndexKey?
    @ObservationIgnored private var originalQuery: String
    @ObservationIgnored private(set) var indexTask: Task<Void, Never>?
    @ObservationIgnored private(set) var queryTask: Task<Void, Never>?
    @ObservationIgnored private(set) var executionTask: Task<Void, Never>?
    private struct IndexKey: Equatable { let token: UUID; let updated: Date?; let ignored: Bool }

    init(store: RepositoryStore, reader: any ToolbarSearchReading = GitToolbarSearchReader()) {
        self.store = store; self.reader = reader; text = store.search; originalQuery = store.search; resultsToken = store.repositoryToken
    }
    deinit { indexTask?.cancel(); queryTask?.cancel(); executionTask?.cancel() }
    var actionsOnly: Bool { text.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
    var query: String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return actionsOnly ? String(value.dropFirst()).trimmingCharacters(in: .whitespaces) : value
    }
    var hasContext: Bool { !actionsOnly && store.destination.searchPlaceholder != nil }
    var presentation: ToolbarSearchPresentation {
        ToolbarSearchPresentation(visible: visible && store.canUseRepository, contextTitle: hasContext ? (query.isEmpty ? String(localized: "Search in \(store.destination.title)") : String(localized: "Filter \(store.destination.title) for “\(query)”")) : nil, results: results, selection: selection, loading: loading || searching, failure: failure, executing: submitted)
    }
    func beginEditing() {
        guard store.canUseRepository, !submitted else { return }
        if !focused { originalQuery = store.search; selection = nil }
        focused = true; visible = true; submitted = false
        refreshItems()
    }
    func beginActions() {
        guard store.canUseRepository, !submitted else { return }
        originalQuery = store.search; text = "> "; focused = true; visible = true; submitted = false; selection = nil
        refreshItems()
    }
    func beginContextSearch() { text = store.search; selection = nil; beginEditing() }
    func updateText(_ value: String) {
        guard store.canUseRepository, resultsToken == store.repositoryToken else { contextChanged(); return }
        if !focused { originalQuery = store.search; focused = true }
        text = value; selection = nil; results = []
        if !actionsOnly, store.destination.searchPlaceholder != nil { store.search = value }
        visible = store.canUseRepository; submitted = false
        scheduleResults()
    }
    func endEditing() {
        focused = false; dismiss()
        if actionsOnly { text = store.search }
    }
    func dismiss() { visible = false; queryTask?.cancel(); queryGeneration = UUID(); searching = false }
    func cancel() {
        dismiss(); selection = nil
        if actionsOnly { text = store.search }
    }
    func filterCurrentView() { guard hasContext else { return }; selection = nil; dismiss() }
    func contextChanged() { endEditing(); text = store.search; originalQuery = store.search }
    func externalQueryChanged() { if !actionsOnly, text != store.search { text = store.search } }
    func invalidate() {
        indexTask?.cancel(); indexGeneration = UUID(); loadedKey = nil; loadingKey = nil; fileItems = []; loading = false
        if resultsToken != store.repositoryToken { endEditing(); text = store.search; results = []; selection = nil; resultsToken = store.repositoryToken }
        if focused, store.canUseRepository { refreshItems() }
    }
    func stop() { endEditing(); indexTask?.cancel(); executionTask?.cancel(); indexGeneration = UUID(); loadingKey = nil; loading = false }
    func retry() { loadedKey = nil; loadingKey = nil; refreshItems() }

    func move(_ offset: Int) {
        if !visible { beginEditing() }
        guard !results.isEmpty else { return }
        if hasContext, offset < 0, selection == nil || selection == results.first?.id { selection = nil; return }
        selection = QuickActionSearch.move(selection, in: results, offset: offset)
    }
    @discardableResult func submit(_ item: QuickActionItem? = nil) -> Bool {
        guard !submitted, store.canUseRepository, resultsToken == store.repositoryToken else { return false }
        let chosen = results.first { $0.id == (item?.id ?? selection) }
        guard let chosen else { if item == nil, selection == nil, hasContext { dismiss(); return true }; return false }
        guard visible else { return false }
        submitted = true; dismiss()
        store.search = originalQuery; text = originalQuery
        let token = resultsToken, targetStore = store
        executionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard !Task.isCancelled, targetStore.canUseRepository, token == targetStore.repositoryToken else { self?.submitted = false; return }
            targetStore.runQuickAction(chosen, repositoryToken: token)
            self?.submitted = false
        }
        return true
    }

    private func refreshItems() {
        guard store.canUseRepository, let repository = store.repository else { dismiss(); return }
        let key = IndexKey(token: store.repositoryToken, updated: store.lastUpdated, ignored: store.showIgnoredFiles)
        if loadedKey != key, loadingKey != key { fileItems = [] }
        baseItems = store.quickActionItems(files: []); resultsToken = store.repositoryToken
        scheduleResults()
        guard loadedKey != key, loadingKey != key else { return }
        indexTask?.cancel(); let generation = UUID(); indexGeneration = generation; loadingKey = key; loading = true; failure = nil
        let reader = reader, hasHEAD = store.snapshot?.hasHEAD == true
        indexTask = Task { [weak self] in
            do {
                let files = try await reader.files(in: repository, includeIgnored: key.ignored)
                guard !Task.isCancelled else { return }
                let items = await Task.detached(priority: .userInitiated) { QuickActionSearch.fileItems(files, hasHEAD: hasHEAD) }.value
                guard let self, !Task.isCancelled, self.indexGeneration == generation, self.store.repositoryToken == key.token else { return }
                self.fileItems = items; self.loadedKey = key; self.loadingKey = nil; self.loading = false
                if self.focused { self.scheduleResults() }
            } catch {
                guard let self, !Task.isCancelled, self.indexGeneration == generation, self.store.repositoryToken == key.token else { return }
                self.failure = String(localized: "File search unavailable: \(error.localizedDescription)"); self.loadingKey = nil; self.loading = false
            }
        }
    }
    private func scheduleResults() {
        queryTask?.cancel(); let generation = UUID(); queryGeneration = generation; searching = true
        let query = query, token = store.repositoryToken, repository = store.repository, reader = reader
        let all = baseItems + fileItems
        let items = query.isEmpty ? baseItems.filter { if case .command = $0.target { return true }; if case .destination = $0.target { return true }; return false } : all
        queryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            let matches = await Task.detached(priority: .userInitiated) { Array(QuickActionSearch.results(items, query: query).prefix(12)) }.value
            guard let self, !Task.isCancelled, self.queryGeneration == generation, self.store.repositoryToken == token else { return }
            self.apply(matches, token: token)
            guard (7...64).contains(query.count), query.allSatisfy(\.isHexDigit), let repository else { return }
            if let commit = try? await reader.commit(query, in: repository) {
                guard !Task.isCancelled, self.queryGeneration == generation, self.store.repositoryToken == token else { return }
                let item = QuickActionItem(id: "commit:" + commit.hash, title: commit.subject, subtitle: String(localized: "Commit · \(commit.hash)"), icon: "clock", target: .commit(commit))
                if !matches.contains(where: { $0.id == item.id }) { self.apply(Array(([item] + matches).prefix(12)), token: token) }
            }
        }
    }
    private func apply(_ items: [QuickActionItem], token: UUID) {
        results = items; resultsToken = token; searching = false
        if let selection, !items.contains(where: { $0.id == selection }) { self.selection = nil }
        if !hasContext, selection == nil { selection = items.first?.id }
    }
}
