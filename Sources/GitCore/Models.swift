import Foundation

public struct FileChange: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let index: Character
    public let worktree: Character
    public var isUntracked: Bool { index == "?" && worktree == "?" }
    public var isConflicted: Bool {
        ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(String([index, worktree]))
    }
    public var isStaged: Bool { index != " " && index != "?" && !isConflicted }
    public var isUnstaged: Bool { worktree != " " || isUntracked }
    public var displayStatus: String {
        if isConflicted { return "Conflict" }
        if isUntracked { return "Untracked" }
        let code = worktree == " " ? index : worktree
        return ["A": "Added", "M": "Modified", "D": "Deleted", "R": "Renamed", "C": "Copied", "T": "Type changed"][code] ?? "Changed"
    }
}

public struct Commit: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let parents: [String]
    public let author: String
    public let email: String
    public let date: Date
    public let subject: String
    public let decorations: [String]
    public var shortHash: String { String(hash.prefix(8)) }
    public var initials: String { author.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined() }
}

public struct Reference: Identifiable, Hashable, Sendable {
    public var id: String { fullName }
    public let fullName: String
    public let name: String
    public let hash: String
    public let upstream: String
    public let isCurrent: Bool
    public var isLocal: Bool { fullName.hasPrefix("refs/heads/") }
    public var isRemote: Bool { fullName.hasPrefix("refs/remotes/") }
    public var isTag: Bool { fullName.hasPrefix("refs/tags/") }
}

public struct Stash: Identifiable, Hashable, Sendable {
    public var id: String { name + hash }
    public let hash: String
    public let name: String
    public let subject: String
    public var stackToken: String = ""
    public var date: Date = .distantPast
}

public struct RepositorySnapshot: Sendable {
    public var unresolvedUpstream: String? {
        guard let current = references.first(where: \.isCurrent), !current.upstream.isEmpty,
              !references.contains(where: { $0.name == current.upstream || $0.fullName == current.upstream }) else { return nil }
        return current.upstream
    }
    public let root: URL
    public let branch: String
    public let changes: [FileChange]
    public let commits: [Commit]
    public let references: [Reference]
    public let stashes: [Stash]
    public let remotes: [String]
    public let ahead: Int
    public let behind: Int
    public let hasHEAD: Bool
    public let identity: GitIdentity
    public let operation: RepositoryOperation
    public let historyCount: Int
    public let head: HeadPosition
    public let historyCountIsExact: Bool
}

public struct ChangedPath: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let status: String
    public let path: String
}

public struct CommitDetail: Sendable {
    public let message: String
    public let files: [ChangedPath]
    public let metadata: CommitMetadata
    public let statistics: [String: FileStatistics]
    public var additions: Int { statistics.values.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { statistics.values.reduce(0) { $0 + $1.deletions } }
}

public struct GitIdentity: Sendable {
    public let name: String
    public let email: String
}

public enum RepositoryOperation: String, Sendable, Codable {
    case none, merge, rebase, cherryPick, revert
}

public struct CommitMetadata: Sendable {
    public let author: String
    public let authorEmail: String
    public let authorDate: Date
    public let committer: String
    public let committerEmail: String
    public let committerDate: Date
    public let tree: String
}

public struct FileStatistics: Sendable {
    public let additions: Int
    public let deletions: Int
    public let isBinary: Bool
}

public struct HistoryOptions: Sendable, Equatable, Codable {
    public var limit = 500
    public var query = ""
    public var firstParent = false
    public var sortByDate = false
    public init() {}
}

public struct BranchComparison: Sendable {
    public let branch: Reference
    public let ahead: Int
    public let behind: Int
    public let commits: [Commit]
    public let files: [ChangedPath]
    public var isMerged: Bool { ahead == 0 }
}

public struct RepositoryConfiguration: Sendable {
    public let identity: GitIdentity
    public let remotes: [RemoteConfiguration]
    public let description: String
    public let signCommits: Bool
    public let signingKey: String
}

public struct RemoteConfiguration: Identifiable, Hashable, Sendable, Codable {
    public var id: String { name }
    public let name: String
    public let fetchURL: String
    public let pushURL: String
    public var fetchURLs: [String] = []
    public var pushURLs: [String] = []
    public var refspecs: [String] = []
}

public struct CommitOutcome: Sendable {
    public let undoWarning: String?
}
