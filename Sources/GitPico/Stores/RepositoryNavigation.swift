import Foundation

/// Workspace visits contain repositories only, never pages or commits.
struct RepositoryVisitHistory: Codable, Equatable {
    var back: [String] = []
    var current: String?
    var forward: [String] = []
    mutating func visit(_ path: String) {
        guard path != current else { return }
        if let current { back.append(current) }
        back = Array(back.suffix(100))
        current = path
        forward = []
    }
}

enum RepositoryVisitDirection { case back, forward }

extension RepositoryWorkspace {
    func recordRepositoryVisit(_ tab: RepositoryTab) {
        guard !restoringSession, tab.id == selectedID, !tab.isOpening, !tab.showsRepositoryPicker,
              let path = tab.root?.path, tab.store.snapshot?.root.path == path else { return }
        repositoryVisits.visit(path)
    }
    func rememberRepositoryState(_ tab: RepositoryTab) {
        guard let path = tab.root?.path, tab.store.snapshot?.root.path == path, !tab.isOpening else { return }
        repositoryStates[path] = tab.store.sessionState
        repositoryStateOrder.removeAll { $0 == path }
        repositoryStateOrder.append(path)
        while repositoryStateOrder.count > 100 { repositoryStates.removeValue(forKey: repositoryStateOrder.removeFirst()) }
    }
    func canNavigateRepositories(_ direction: RepositoryVisitDirection, from store: RepositoryStore) -> Bool {
        guard let tab = tab(for: store), selectedID == tab.id,
              !isNavigatingRepositories, !tab.isBusy else { return false }
        return !(direction == .back ? repositoryVisits.back : repositoryVisits.forward).isEmpty
    }
    func navigateRepositories(_ direction: RepositoryVisitDirection, from store: RepositoryStore) async {
        guard canNavigateRepositories(direction, from: store),
              let path = (direction == .back ? repositoryVisits.back : repositoryVisits.forward).last else { return }
        let previous = repositoryVisits
        isNavigatingRepositories = true
        defer { isNavigatingRepositories = false; scheduleSessionSave() }
        if let existing = tabs.first(where: { $0.root?.path == path && $0.store.snapshot?.root.path == path }) {
            guard !existing.isOpening else { return }
            existing.isChoosingRepository = false
            select(existing.id, recordingVisit: false)
        } else {
            await open(URL(fileURLWithPath: path), from: store, recordingVisit: false)
        }
        // Unavailable repositories and newer user selections cannot consume a visit.
        guard activeTab.root?.path == path, activeStore.snapshot?.root.path == path,
              !activeTab.showsRepositoryPicker, repositoryVisits == previous else { return }
        if direction == .back {
            repositoryVisits.back.removeLast()
            if let current = previous.current { repositoryVisits.forward.append(current) }
        } else {
            repositoryVisits.forward.removeLast()
            if let current = previous.current { repositoryVisits.back.append(current) }
        }
        repositoryVisits.current = path
    }
}

extension RepositoryStore {
    var canGoBack: Bool { workspace?.canNavigateRepositories(.back, from: self) == true }
    var canGoForward: Bool { workspace?.canNavigateRepositories(.forward, from: self) == true }
    func goBack() { Task { await workspace?.navigateRepositories(.back, from: self) } }
    func goForward() { Task { await workspace?.navigateRepositories(.forward, from: self) } }
}
