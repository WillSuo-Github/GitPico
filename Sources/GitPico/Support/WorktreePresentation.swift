import Foundation
import GitCore

/// Display labels never change a worktree's path, branch or persistent identity.
struct WorktreePresentation {
    let entries: [ManagedWorktree]
    let currentPath: String?
    let currentBranch: String?
    private let baseTitles: [String: String]
    private let titleCounts: [String: Int]

    init(entries: [ManagedWorktree], currentPath: String? = nil, currentBranch: String? = nil) {
        self.entries = entries; self.currentPath = currentPath; self.currentBranch = currentBranch
        let nameCounts = Dictionary(grouping: entries, by: \.name).mapValues(\.count)
        var titles: [String: String] = [:]
        for entry in entries {
            let ref = entry.path == currentPath ? currentBranch : entry.branch
            let branch = ref.flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
            titles[entry.path] = !entry.isMain && (nameCounts[entry.name] ?? 0) > 1 ? (branch ?? entry.name) : entry.name
        }
        baseTitles = titles
        titleCounts = Dictionary(grouping: Array(titles.values), by: { $0 }).mapValues(\.count)
    }

    func branch(for entry: ManagedWorktree) -> String? {
        let ref = entry.path == currentPath ? currentBranch : entry.branch
        guard let ref, ref.hasPrefix("refs/heads/") else { return nil }
        return String(ref.dropFirst("refs/heads/".count))
    }
    func title(for entry: ManagedWorktree) -> String {
        let base = baseTitles[entry.path] ?? entry.name
        let repeatedTitle = (titleCounts[base] ?? 0) > 1
        return !entry.isMain && repeatedTitle ? base + " · " + location(for: entry) : base
    }
    /// Keep enough parent components visible to distinguish even detached, identically named trees.
    func location(for entry: ManagedWorktree) -> String {
        let components = URL(fileURLWithPath: entry.path).pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else { return entry.path }
        for depth in min(2, components.count)...components.count {
            let suffix = Array(components.suffix(depth))
            if !entries.contains(where: { other in
                other.path != entry.path && Array(URL(fileURLWithPath: other.path).pathComponents.suffix(depth)) == suffix
            }) { return suffix.joined(separator: "/") }
        }
        return entry.path
    }
}

extension RepositoryStore {
    var currentWorktree: ManagedWorktree? { worktrees.first { $0.path == snapshot?.root.path } }
    var isLinkedWorktree: Bool { currentWorktree.map { !$0.isMain && !$0.isBare } ?? false }
    var repositoryDisplayName: String {
        let path = worktrees.first(where: \.isMain)?.path ?? snapshot?.root.path
        return path.map { library.displayName(for: $0) } ?? "GitPico"
    }
    var worktreePresentation: WorktreePresentation {
        WorktreePresentation(entries: worktrees, currentPath: snapshot?.root.path, currentBranch: snapshot?.head.branch)
    }
    func worktreeTitle(_ entry: ManagedWorktree) -> String {
        entry.isMain ? library.displayName(for: entry.path) : worktreePresentation.title(for: entry)
    }
    var repositoryWindowTitle: String {
        guard isLinkedWorktree, let currentWorktree else {
            return snapshot.map { library.displayName(for: $0.root.path) } ?? "GitPico"
        }
        return repositoryDisplayName + " — " + worktreeTitle(currentWorktree) + " [" + String(localized: "Worktree") + "]"
    }
}
