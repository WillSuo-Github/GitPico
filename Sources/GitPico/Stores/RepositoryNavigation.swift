import Foundation

/// Paths retain the legacy on-disk representation; the library is a distinct destination.
enum RepositoryVisitDestination: Codable, Equatable {
    case library
    case repository(String)

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "library" ? .library : .repository(value)
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .library: try container.encode("library")
        case .repository(let path): try container.encode(path)
        }
    }
    var isValid: Bool {
        switch self {
        case .library: true
        case .repository(let path): path.hasPrefix("/") && !path.utf8.contains(0)
        }
    }
}

/// Workspace visits include the library and repositories, never repository pages or commits.
struct RepositoryVisitHistory: Codable, Equatable {
    var back: [RepositoryVisitDestination] = []
    var current: RepositoryVisitDestination? = .library
    var forward: [RepositoryVisitDestination] = []
    mutating func visit(_ path: String) { visit(.repository(path)) }
    mutating func visit(_ destination: RepositoryVisitDestination) {
        guard destination != current else { return }
        if let current { back.append(current) }
        back = Array(back.suffix(100))
        current = destination
        forward = []
    }
}

enum RepositoryVisitDirection { case back, forward }

extension RepositoryWorkspace {
    func recordRepositoryVisit(_ tab: RepositoryTab) {
        guard !restoringSession, tab.id == selectedID, !tab.isOpening else { return }
        if tab.showsRepositoryPicker {
            repositoryVisits.visit(.library)
        } else if let path = tab.root?.path, tab.store.snapshot?.root.path == path {
            repositoryVisits.visit(path)
        }
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
              let destination = (direction == .back ? repositoryVisits.back : repositoryVisits.forward).last else { return }
        let previous = repositoryVisits
        isNavigatingRepositories = true
        defer { isNavigatingRepositories = false; scheduleSessionSave() }
        switch destination {
        case .library:
            showRepositories(from: store, recordingVisit: false)
        case .repository(let path):
            if let existing = tabs.first(where: { $0.root?.path == path && $0.store.snapshot?.root.path == path }) {
                guard !existing.isBusy else { return }
                existing.isChoosingRepository = false
                select(existing.id, recordingVisit: false)
            } else {
                await open(URL(fileURLWithPath: path), from: store, recordingVisit: false)
            }
        }
        // Unavailable repositories and newer user selections cannot consume a visit.
        guard repositoryVisits == previous else { return }
        switch destination {
        case .library: guard activeTab.showsRepositoryPicker else { return }
        case .repository(let path):
            guard activeTab.root?.path == path, activeStore.snapshot?.root.path == path,
                  !activeTab.showsRepositoryPicker else { return }
        }
        if direction == .back {
            repositoryVisits.back.removeLast()
            if let current = previous.current { repositoryVisits.forward.append(current) }
        } else {
            repositoryVisits.forward.removeLast()
            if let current = previous.current { repositoryVisits.back.append(current) }
        }
        repositoryVisits.current = destination
    }
}

extension RepositoryStore {
    var canGoBack: Bool { workspace?.canNavigateRepositories(.back, from: self) == true }
    var canGoForward: Bool { workspace?.canNavigateRepositories(.forward, from: self) == true }
    func goBack() { Task { await workspace?.navigateRepositories(.back, from: self) } }
    func goForward() { Task { await workspace?.navigateRepositories(.forward, from: self) } }
}
