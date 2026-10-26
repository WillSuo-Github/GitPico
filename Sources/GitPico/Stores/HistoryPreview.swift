import Foundation
import GitCore

protocol HistoryReading: Sendable {
    func resolve(_ reference: String?, in repository: GitRepository) async throws -> HistoryRevision
    func page(at revision: HistoryRevision, options: HistoryOptions, in repository: GitRepository) async throws -> CommitHistoryPage
}
struct GitHistoryReader: HistoryReading {
    func resolve(_ reference: String?, in repository: GitRepository) async throws -> HistoryRevision { try await repository.resolveHistory(reference) }
    func page(at revision: HistoryRevision, options: HistoryOptions, in repository: GitRepository) async throws -> CommitHistoryPage { try await repository.historyPage(at: revision, options: options) }
}
struct HistoryGroup: Identifiable, Sendable { let id: String; let title: String; var commits: [Commit] }
struct HistoryPresentation: Sendable {
    let id = UUID()
    let page: CommitHistoryPage
    let graph: [String:GraphRow]
    let graphWidth: Double
    let groups: [HistoryGroup]
    static let empty = HistoryPresentation(page: CommitHistoryPage(commits: [], hasMore: false), graph: [:], graphWidth: 29, groups: [])
    nonisolated static func make(_ page: CommitHistoryPage, firstParent: Bool) -> Self {
        let graph = CommitGraph.layout(page.commits, firstParentOnly: firstParent)
        var groups: [HistoryGroup] = []
        let style = Date.FormatStyle().month(.wide).year()
        var previousMonth: DateComponents?
        let calendar = Calendar.current
        var monthOccurrences: [String: Int] = [:]
        for commit in page.commits {
            let month = calendar.dateComponents([.year,.month], from: commit.date)
            if month == previousMonth { groups[groups.count - 1].commits.append(commit) }
            else {
                // A different branch tip must not replace the section and all its shared rows.
                // Topological order may revisit a month, so distinguish its contiguous runs.
                let key = "\(month.era ?? 0)-\(month.year ?? 0)-\(month.month ?? 0)"
                let occurrence = monthOccurrences[key, default: 0]
                monthOccurrences[key] = occurrence + 1
                groups.append(HistoryGroup(id: "\(key):\(occurrence)", title: commit.date.formatted(style).uppercased(), commits: [commit]))
                previousMonth = month
            }
        }
        return Self(page: page, graph: graph, graphWidth: Double(max(1,graph.values.map(\.laneCount).max() ?? 1) * 13 + 16), groups: groups)
    }
}
struct HistoryCacheKey: Hashable {
    let scope: String
    let revision: String
    let limit: Int
    let query: String
    let firstParent: Bool
    let dateOrder: Bool
    init(reference: String?, revision: HistoryRevision, options: HistoryOptions) {
        scope = reference ?? "*"; self.revision = revision.identity; limit = options.limit; query = options.query; firstParent = options.firstParent; dateOrder = options.sortByDate
    }
}
extension RepositoryStore {
    var visibleCommits: [Commit] { historyPresentation.page.commits }
    var isHistoryDestination: Bool { destination == .history || destination.ref != nil }
    func cancelHistoryPreview() {
        historyGeneration = UUID(); historyTask?.cancel(); historyTask = nil; isLoadingHistory = false
    }
    func cancelPreviewWork() { cancelHistoryPreview(); detailTask?.cancel(); detailTask = nil; detailToken = UUID(); workingDiffRequest = nil; isLoadingDiff = false }
    func clearHistoryCache() { historyCache = [:]; historyCacheOrder = []; historyRevisionHints = [:] }
    func cachedHistory(_ key: HistoryCacheKey) -> HistoryPresentation? {
        guard let entry = historyCache[key] else { return nil }
        historyCacheOrder.removeAll { $0 == key }; historyCacheOrder.append(key)
        return entry
    }
    func cacheHistory(_ value: HistoryPresentation, key: HistoryCacheKey) {
        historyCache[key] = value; historyCacheOrder.removeAll { $0 == key }; historyCacheOrder.append(key)
        while historyCacheOrder.count > 16 || historyCache.values.reduce(0, { $0 + $1.page.commits.count }) > 20_000 {
            guard historyCacheOrder.count > 1 else { break }
            historyCache.removeValue(forKey: historyCacheOrder.removeFirst())
        }
    }
    func showHistory(_ value: HistoryPresentation, preservingSelection: Bool) {
        let previousSelection = selectedCommit?.hash
        if historyPresentation.id != value.id { historyPresentation = value }
        if preservingSelection, let selectedCommit, value.page.commits.contains(where: { $0.hash == selectedCommit.hash }) {
            if commitDetail == nil && !isLoadingDiff { selectCommit(selectedCommit) }
            revealHistorySelection()
            return
        }
        if let desired = value.page.commits.first(where: { $0.hash == pendingHistorySelection }) { selectCommit(desired) }
        else if let first = value.page.commits.first { selectCommit(first) }
        else { selectedCommit = nil; commitDetail = nil; selectedCommitPath = nil; diff = ""; isLoadingDiff = false }
        if !historyNeedsReveal, previousSelection != selectedCommit?.hash { historyNeedsReveal = true; pendingHistorySelection = nil }
        revealHistorySelection()
    }
    func requestHistory(preservingSelection: Bool = true, debounce: Duration = .zero) {
        guard let repository, isHistoryDestination else { return }
        cancelHistoryPreview()
        let generation = historyGeneration, token = repositoryToken, target = destination, reference = destination.ref, options = historyOptions, reader = historyReader
        let scope = reference ?? "*"
        let hint = historyRevisionHints[scope]
        let cached = hint.flatMap { cachedHistory(HistoryCacheKey(reference: reference, revision: $0, options: options)) }
        if let cached { showHistory(cached, preservingSelection: preservingSelection) }
        else if !preservingSelection { historyPresentation = .empty }
        let preserveAfterLoad = preservingSelection || cached != nil
        isLoadingHistory = cached == nil; historyError = nil
        historyTask = Task { [weak self] in
            do {
                if debounce > .zero { try await Task.sleep(for: debounce) }
                else { await Task.yield() }
                try Task.checkCancellation()
                let revision = try await reader.resolve(reference, in: repository)
                try Task.checkCancellation()
                guard let self, self.historyGeneration == generation, self.repositoryToken == token, self.destination == target, self.historyOptions == options else { return }
                let key = HistoryCacheKey(reference: reference, revision: revision, options: options)
                self.historyRevisionHints[scope] = revision
                if let existing = self.cachedHistory(key) {
                    self.showHistory(existing, preservingSelection: preserveAfterLoad); self.isLoadingHistory = false; return
                }
                let page = try await reader.page(at: revision, options: options, in: repository)
                let worker = Task.detached(priority: .userInitiated) { HistoryPresentation.make(page, firstParent: options.firstParent) }
                let value = await worker.value
                try Task.checkCancellation()
                guard self.historyGeneration == generation, self.repositoryToken == token, self.destination == target, self.historyOptions == options else { return }
                self.cacheHistory(value, key: key); self.showHistory(value, preservingSelection: preserveAfterLoad); self.isLoadingHistory = false
            } catch is CancellationError { }
            catch {
                guard let self, self.historyGeneration == generation, self.repositoryToken == token, self.destination == target else { return }
                self.isLoadingHistory = false; self.historyError = error.localizedDescription
            }
        }
    }
}
