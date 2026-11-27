import Foundation
import GitCore

struct NavigationBookmark: Codable, Equatable {
    let search: String
    let options: HistoryOptions
    let commitHash: String?
    let scrollOffset: Double?

    init(search: String, options: HistoryOptions, commitHash: String?, scrollOffset: Double? = nil) {
        self.search = search
        self.options = options
        self.commitHash = commitHash
        self.scrollOffset = scrollOffset.flatMap { $0.isFinite ? max(0, $0) : nil }
    }
}
struct HistoryReveal: Equatable {
    let id = UUID()
    let hash: String
    let atTop: Bool
    let scrollOffset: CGFloat?

    init(hash: String, atTop: Bool, scrollOffset: CGFloat? = nil) {
        self.hash = hash
        self.atTop = atTop
        self.scrollOffset = scrollOffset.flatMap { $0.isFinite ? max(0, $0) : nil }
    }
}

extension RepositoryStore {
    func finishRepositorySettings() {
        showingRepositorySettings = false
        if let destination = settingsNavigationRequest {
            settingsNavigationRequest = nil
            navigate(destination)
        }
    }
    func currentHistoryScrollOffset() -> Double? {
        guard isHistoryDestination else { return nil }
        if let live = historyScrollOffsetProvider?.read(historyPresentation.id, historyReveal?.id) {
            return live.isFinite ? max(0, Double(live)) : nil
        }
        if let revealOffset = historyReveal?.scrollOffset {
            return revealOffset.isFinite ? max(0, Double(revealOffset)) : nil
        }
        if let pending = pendingHistoryScrollOffset {
            return pending.isFinite ? max(0, pending) : nil
        }
        return nil
    }
    func rememberNavigation() {
        var options = historyOptions
        if isHistoryDestination, options.query != search { options.query = search; options.limit = 500 }
        navigationBookmarks[destination] = NavigationBookmark(
            search: search,
            options: options,
            commitHash: selectedCommit?.hash,
            scrollOffset: currentHistoryScrollOffset()
        )
        navigationBookmarkOrder.removeAll { $0 == destination }
        navigationBookmarkOrder.append(destination)
        while navigationBookmarkOrder.count > 32 { navigationBookmarks.removeValue(forKey: navigationBookmarkOrder.removeFirst()) }
    }
    func restoreNavigation(_ target: Destination) {
        let bookmark = navigationBookmarks[target]
        search = bookmark?.search ?? ""
        if let bookmark { historyOptions = bookmark.options }
        else { historyOptions.query = ""; historyOptions.limit = 500 }
        pendingHistorySelection = bookmark?.commitHash
        pendingHistoryScrollOffset = bookmark?.scrollOffset.flatMap { $0.isFinite ? max(0, $0) : nil }
        historyNeedsReveal = true
        historyReveal = nil
    }
    func revealHistorySelection() {
        guard historyNeedsReveal, let selectedCommit else { return }
        let matchedBookmark = pendingHistorySelection != nil && pendingHistorySelection == selectedCommit.hash
        let scrollOffset = matchedBookmark ? pendingHistoryScrollOffset.map { CGFloat($0) } : nil
        historyReveal = HistoryReveal(hash: selectedCommit.hash, atTop: !matchedBookmark, scrollOffset: scrollOffset)
        historyNeedsReveal = false; pendingHistorySelection = nil; pendingHistoryScrollOffset = nil
    }
    var isChoosingRepository: Bool { workspace?.tab(for: self)?.showsRepositoryPicker == true }
    var isOpeningRepository: Bool { isOpeningInPlace || workspace?.tab(for: self)?.isOpening == true }
    var canInspectRepository: Bool { snapshot != nil && !isChoosingRepository && !isOpeningRepository }
    var canUseRepository: Bool { canInspectRepository && !isBusy }
    var canFetch: Bool { canUseRepository && !isFetching && snapshot?.remotes.isEmpty == false }
    var canBrowseHistory: Bool { canInspectRepository && snapshot?.hasHEAD == true }
    var canIntegrate: Bool { canUseRepository && snapshot?.hasHEAD == true && snapshot?.operation == RepositoryOperation.none }
    var canRemoteIntegrate: Bool { canIntegrate && !isFetching && snapshot?.remotes.isEmpty == false }
    var canSynchronize: Bool { canRemoteIntegrate && snapshot?.references.contains { $0.isCurrent && !$0.upstream.isEmpty } == true }
    var previewedReference: Reference? { snapshot?.references.first { $0.fullName == destination.ref } }
    func activateSidebarSelection(_ selection: Set<Destination>) {
        guard selection.count == 1, let target = selection.first else { return }
        switch target {
        case .reference(let name):
            guard let ref = snapshot?.references.first(where: { $0.fullName == name }) else { return }
            if ref.isLocal { switchBranch(ref) }
            else if ref.isRemote { switchRemoteBranch(ref) }
        case .worktree(let path):
            guard let entry = worktrees.first(where: { $0.path == path }), !entry.isBare, entry.prunable == nil else { return }
            openWorktree(entry)
        default: break
        }
    }
    func checkoutUnavailableReason(_ ref: Reference) -> String? {
        if !canUseRepository { return String(localized: "Wait for the current repository operation.") }
        if !ref.isLocal { return String(localized: "Check out a local branch.") }
        if ref.isCurrent { return String(localized: "This branch is already checked out.") }
        if snapshot?.operation != RepositoryOperation.none { return String(localized: "Finish or abort the current operation first.") }
        if !metadataDirty.contains(.worktrees), let entry = worktrees.first(where: { $0.branch == ref.fullName && $0.path != snapshot?.root.path }) { return String(localized: "Checked out in \(entry.path)") }
        return nil
    }
    var navigationSubtitle: String {
        guard snapshot != nil else { return String(localized: "A little clarity for every commit") }
        if let reference = destination.ref { return String(localized: "History · \(Destination.reference(reference).title)") }
        return destination.title
    }
}
