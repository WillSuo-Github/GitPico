import Foundation

public struct GitFlowConfiguration: Codable, Equatable, Sendable {
    public var production: String
    public var development: String
    public var feature: String
    public var release: String
    public var hotfix: String
    public var support: String
    public var versionTag: String
    public init(production: String = "main", development: String = "develop", feature: String = "feature/", release: String = "release/", hotfix: String = "hotfix/", support: String = "support/", versionTag: String = "") {
        self.production = production; self.development = development; self.feature = feature; self.release = release; self.hotfix = hotfix; self.support = support; self.versionTag = versionTag
    }
    var values: [String:String] { ["gitflow.branch.master":production, "gitflow.branch.develop":development, "gitflow.prefix.feature":feature, "gitflow.prefix.release":release, "gitflow.prefix.hotfix":hotfix, "gitflow.prefix.support":support, "gitflow.prefix.versiontag":versionTag] }
    public func prefix(_ kind: GitFlowKind) -> String { switch kind { case .feature: feature; case .release: release; case .hotfix: hotfix; case .support: support } }
    public func kind(of branch: String) -> GitFlowKind? { GitFlowKind.allCases.first { branch.hasPrefix(prefix($0)) && branch != prefix($0) } }
}
public enum GitFlowKind: String, CaseIterable, Codable, Sendable { case feature = "Feature", release = "Release", hotfix = "Hotfix", support = "Support" }
public enum GitFlowAction: String, Codable, Sendable { case configure, start, track, finish }
public struct GitFlowGuard: Codable, Equatable, Sendable {
    let head: HeadPosition
    let refs: [String:String]
    let config: Data?
    let index: Data?
}
public struct GitFlowPlan: Sendable {
    public let action: GitFlowAction
    public let configuration: GitFlowConfiguration
    public let kind: GitFlowKind
    public let name: String
    public let branch: String
    public let targets: [String]
    public let tag: String?
    public let message: String
    public let keepBranch: Bool
    public let signTag: Bool
    let repository: String
    let before: GitFlowGuard
    let source: String
    let remoteRef: String?
}
public struct GitFlowStep: Codable, Equatable, Sendable {
    let operation: String
    let target: String
    let source: String?
}
public struct GitFlowRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let repository: String
    public let kind: GitFlowKind
    public let branch: String
    public let title: String
    public let tag: String?
    public let message: String
    public let signTag: Bool
    public var state: String
    public var next: Int
    public var diagnostic: String?
    public var stepCount: Int { steps.count }
    let configuration: GitFlowConfiguration
    let initial: GitFlowGuard
    var expected: GitFlowGuard
    let steps: [GitFlowStep]
    var waiting: Bool = false
}
