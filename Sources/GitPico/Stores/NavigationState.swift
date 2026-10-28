import Foundation
import GitCore

struct NavigationBookmark: Codable, Equatable {
    let search: String
    let options: HistoryOptions
    let commitHash: String?
}
struct HistoryReveal: Equatable {
    let id = UUID()
    let hash: String
    let atTop: Bool
}

extension RepositoryStore {
    func rememberNavigation() {
        var options = historyOptions
        if isHistoryDestination, options.query != search { options.query = search; options.limit = 500 }
        navigationBookmarks[destination] = NavigationBookmark(search: search, options: options, commitHash: selectedCommit?.hash)
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
        historyNeedsReveal = true
        historyReveal = nil
    }
    func revealHistorySelection() {
        guard historyNeedsReveal, let selectedCommit else { return }
        historyReveal = HistoryReveal(hash: selectedCommit.hash, atTop: pendingHistorySelection == nil || pendingHistorySelection != selectedCommit.hash)
        historyNeedsReveal = false; pendingHistorySelection = nil
    }
    var isChoosingRepository: Bool { workspace?.tab(for: self)?.showsRepositoryPicker == true }
    var isOpeningRepository: Bool { workspace?.tab(for: self)?.isOpening == true }
    var canUseRepository: Bool { snapshot != nil && !isBusy && !isChoosingRepository && !isOpeningRepository }
    var canBrowseHistory: Bool { canUseRepository && snapshot?.hasHEAD == true }
    var canIntegrate: Bool { canBrowseHistory && snapshot?.operation == RepositoryOperation.none }
    var canSynchronize: Bool { canIntegrate && snapshot?.remotes.isEmpty == false && snapshot?.references.contains { $0.isCurrent && !$0.upstream.isEmpty } == true }
    var previewedReference: Reference? { snapshot?.references.first { $0.fullName == destination.ref } }
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
