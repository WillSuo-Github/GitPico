import Foundation

public struct ReferenceBackup: Codable, Identifiable, Sendable {
    public let id: UUID
    public let fullName: String
    public let hash: String
    public let title: String
    public let date: Date
    public var isStash: Bool { fullName == "refs/stash" }
    public var isTag: Bool { fullName.hasPrefix("refs/tags/") }
}

public struct ReferenceOrganization: Codable, Sendable {
    public var archived: Set<String> = []
    public var pinned: Set<String> = []
    public init() {}
}

public struct StashSaveOptions: Sendable {
    public var message = ""
    public var includeUntracked = true
    public var keepIndex = false
    public var snapshot = false
    public var paths: [String] = []
    public init() {}
}

public struct StashFile: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let status: String
    public let isUntracked: Bool
}

public struct StashDetail: Sendable {
    public let commit: Commit
    public let base: String
    public let files: [StashFile]
    public let statistics: [String: FileStatistics]
}

public struct RemotePushPreview: Sendable {
    public let remote: RemoteConfiguration
    public let source: Reference?
    public let destination: String
    public let remoteHash: String?
    public let setUpstream: Bool
    public let forceWithLease: Bool
    public let pushURL: String
    public var deletes: Bool { source == nil }
}
