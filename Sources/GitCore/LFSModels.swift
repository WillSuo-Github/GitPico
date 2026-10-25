import Foundation

public enum LFSCloneMode: Sendable { case inherit, download, pointersOnly }

public struct LFSRule: Codable, Equatable, Identifiable, Sendable {
    public let pattern: String
    public let source: String
    public let lockable: Bool
    public let tracked: Bool
    public var id: String { source + "\0" + pattern }
    public var relativePattern: String {
        let parent = (source as NSString).deletingLastPathComponent
        return !parent.isEmpty && pattern.hasPrefix(parent + "/") ? String(pattern.dropFirst(parent.count + 1)) : pattern
    }
}
public struct LFSFile: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    public let size: UInt64
    public let checkout: Bool
    public let downloaded: Bool
    public let oid: String
    public var id: String { name }
}
public struct LFSState: Sendable {
    public let available: Bool
    public let version: String
    public let enabled: Bool
    public let hookInstalled: Bool
    public let rules: [LFSRule]
    public let files: [LFSFile]
    public let status: String
}
public enum LFSChange: Sendable {
    case enable(installHook: Bool), disable, track(String, filename: Bool, source: String), untrack(String, source: String)
}
public struct LFSChangePlan: Sendable {
    public let title: String
    public let paths: [String]
    public let preview: String
    let repository: String
    let head: HeadPosition
    let before: [ManagementFile]
    let after: [ManagementFile]
}
public struct LFSChangeRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let title: String
    public let repository: String
    public let head: HeadPosition
    public var state: String
    public var affectedPaths: [String] { before.map(\.path) }
    let before: [ManagementFile]
    let after: [ManagementFile]
}
public enum LFSTransfer: String, CaseIterable, Sendable { case fetch = "Fetch Objects", pull = "Pull Objects", push = "Push Objects", checkout = "Checkout Cached Objects" }
public struct LFSTransferPlan: Sendable {
    public let operation: LFSTransfer
    public let remote: String
    public let hash: String
    public let paths: [String]
    public let endpoint: String
    public let allObjects: Bool
    let repository: String
    let head: HeadPosition
    let guards: [ManagementFile]
}
public struct LFSTransferReport: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let operation: String
    public let remote: String
    public let hash: String
    public let output: String
    public let succeeded: Bool
}
