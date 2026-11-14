import Foundation
import Darwin

/// Transient filesystem state; never persisted in the saved repository library.
enum RepositoryFolderState: Equatable, Sendable {
    case checking, available, missing, unavailable

    var canOpen: Bool { self == .available }
    var warning: String? {
        switch self {
        case .missing: String(localized: "Folder Missing")
        case .unavailable: String(localized: "Folder Unavailable")
        case .checking, .available: nil
        }
    }

    nonisolated static func read(path: String) -> Self {
        var info = stat()
        // Follow symlinks without Foundation resource caching, preserving permission errors.
        guard path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else {
            return errno == ENOENT ? .missing : .unavailable
        }
        return info.st_mode & S_IFMT == S_IFDIR ? .available : .unavailable
    }
}

extension RepositoryLibrary {
    func folderState(for entry: SavedRepository) -> RepositoryFolderState {
        folderStates[entry.path] ?? .checking
    }

    func refreshFolderStates() async {
        let paths = document.repositories.map(\.path)
        let states = await Task.detached(priority: .utility) {
            var states: [String: RepositoryFolderState] = [:]
            for path in paths {
                guard !Task.isCancelled else { break }
                states[path] = .read(path: path)
            }
            return states
        }.value
        guard !Task.isCancelled else { return }
        let currentPaths = Set(document.repositories.map(\.path))
        let currentStates = states.filter { currentPaths.contains($0.key) }
        if folderStates != currentStates { folderStates = currentStates }
    }

    func refreshFolderState(for entry: SavedRepository) async -> RepositoryFolderState {
        let state = await Task.detached(priority: .utility) { RepositoryFolderState.read(path: entry.path) }.value
        if document.repositories.contains(where: { $0.id == entry.id && $0.path == entry.path }) {
            folderStates[entry.path] = state
        }
        return state
    }
}
