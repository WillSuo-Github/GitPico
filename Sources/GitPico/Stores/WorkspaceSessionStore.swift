import Foundation
import GitCore

struct RepositorySessionState: Codable, Equatable {
    var destination: Destination
    var search: String
    var sidebarFilter: String
    var options: HistoryOptions
    var commitHash: String?
    var commitPath: String?
    var workingPath: String?
    var workingSelection: Set<String>
    var staged: Bool
    var showAll: Bool
    var showIgnored: Bool
    var bookmarks: [Destination: NavigationBookmark]
}
struct WorkspaceSessionTab: Codable {
    var id: UUID
    var path: String?
    var choosing: Bool
    var navigation: RepositorySessionState
}
struct WorkspaceWindowGroup: Codable {
    var tabs: [UUID]
    var selected: UUID
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}
struct WorkspaceSession: Codable {
    var version = 1
    var tabs: [WorkspaceSessionTab]
    var selected: UUID
    var windows: [WorkspaceWindowGroup]
    var repositoryVisits: RepositoryVisitHistory? = nil
}

@MainActor final class WorkspaceSessionStore {
    let file: URL
    private(set) var saved: WorkspaceSession?
    private(set) var error: String?
    private var canWrite = false
    private var diskData: Data?
    init(file: URL) { self.file = file; reload() }
    func reload() {
        do {
            try validateStorage()
            let data = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
            guard (data?.count ?? 0) <= 8 * 1024 * 1024 else { throw appFailure("Saved workspace exceeds its size limit.") }
            let session = try data.map { try JSONDecoder().decode(WorkspaceSession.self, from: $0) }
            if let session { try validate(session) }
            saved = session; diskData = data; canWrite = true; error = nil
        } catch { self.error = error.localizedDescription; canWrite = false }
    }
    func save(_ session: WorkspaceSession) throws {
        guard canWrite else { throw appFailure("Saved workspace could not be read. Keep it for recovery before replacing it.") }
        try validateStorage(); try validate(session)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(session)
        guard data.count <= 8 * 1024 * 1024 else { throw appFailure("Saved workspace exceeds its size limit.") }
        let current = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        guard current == diskData else { throw appFailure("Saved workspace changed outside GitPico. Reload it before saving.") }
        if data != diskData {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        diskData = data; saved = session; error = nil
    }
    private func validateStorage() throws {
        for url in [file, file.deletingLastPathComponent()] {
            if let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType {
                guard type != .typeSymbolicLink, url != file || type == .typeRegular else { throw appFailure("Saved workspace storage is not a regular file or contains a symbolic link.") }
            }
        }
    }
    private func validate(_ session: WorkspaceSession) throws {
        let ids = Set(session.tabs.map(\.id))
        guard session.version == 1, !session.tabs.isEmpty, session.tabs.count <= 128,
              ids.count == session.tabs.count, ids.contains(session.selected),
              session.tabs.allSatisfy({ tab in tab.path.map { $0.hasPrefix("/") && !$0.utf8.contains(0) } ?? true }),
              session.windows.count <= 128 else { throw appFailure("Saved workspace is invalid or from an unsupported version.") }
        if let visits = session.repositoryVisits {
            let destinations = visits.back + visits.forward + [visits.current].compactMap { $0 }
            guard visits.back.count + visits.forward.count <= 100,
                  destinations.allSatisfy(\.isValid) else { throw appFailure("Saved repository visits are invalid.") }
        }
        let grouped = session.windows.flatMap(\.tabs)
        guard Set(grouped).count == grouped.count, Set(grouped).isSubset(of: ids), session.windows.allSatisfy({ group in
            !group.tabs.isEmpty && group.tabs.contains(group.selected) && [group.x, group.y, group.width, group.height].allSatisfy(\.isFinite) && group.width >= 500 && group.height >= 300 && group.width <= 20000 && group.height <= 20000
        }) else { throw appFailure("Saved window groups are invalid.") }
    }
}

extension RepositoryStore {
    var sessionState: RepositorySessionState {
        RepositorySessionState(destination: destination, search: search, sidebarFilter: sidebarFilter, options: historyOptions,
            commitHash: selectedCommit?.hash, commitPath: selectedCommitPath, workingPath: selectedChange,
            workingSelection: selectedWorkingFiles, staged: stagedDiff, showAll: showAllFiles, showIgnored: showIgnoredFiles,
            bookmarks: navigationBookmarks)
    }
    func restoreSessionState(_ state: RepositorySessionState) async {
        guard snapshot != nil else { return }
        let target = state.destination.ref.map { name in snapshot?.references.contains(where: { $0.fullName == name }) == true ? state.destination : .history } ?? state.destination
        navigate(target)
        historyOptions = state.options; historyOptions.limit = min(20000, max(500, state.options.limit))
        search = state.search; sidebarFilter = state.sidebarFilter
        navigationBookmarks = state.bookmarks; navigationBookmarkOrder = Array(state.bookmarks.keys)
        showAllFiles = state.showAll; showIgnoredFiles = state.showIgnored
        if isHistoryDestination {
            pendingHistorySelection = state.commitHash
            requestHistory(); await historyTask?.value; await detailTask?.value
            if let path = state.commitPath, commitDetail?.files.contains(where: { $0.path == path }) == true { selectCommitFile(path) }
        } else if target == .workingCopy {
            if showAllFiles || showIgnoredFiles { await refreshFileBrowser() }
            await rebuildWorkingList()
            setWorkingSelection(state.workingSelection.intersection(workingList.paths))
            if let path = state.workingPath, let file = workingList.files.first(where: { $0.path == path }) {
                if let change = file.change { selectChange(change, staged: state.staged) }
                else { selectBrowserFile(file) }
            }
        }
    }
}
