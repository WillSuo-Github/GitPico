import Foundation

extension GitRepository {
    public func gitFlowConfiguration() async throws -> GitFlowConfiguration? {
        let output = try await GitProcess.run(["config", "--null", "--get-regexp", "^gitflow\\."], at: root, allowed: [0,1])
        guard output.status == 0 else { return nil }
        let fields = try configFields(output.data)
        guard let production = fields["gitflow.branch.master"], let development = fields["gitflow.branch.develop"] else { return nil }
        return GitFlowConfiguration(production: production, development: development, feature: fields["gitflow.prefix.feature"] ?? "feature/", release: fields["gitflow.prefix.release"] ?? "release/", hotfix: fields["gitflow.prefix.hotfix"] ?? "hotfix/", support: fields["gitflow.prefix.support"] ?? "support/", versionTag: fields["gitflow.prefix.versiontag"] ?? "")
    }
    func validateFlowConfiguration(_ config: GitFlowConfiguration) async throws {
        try await validateReferenceName(config.production); try await validateReferenceName(config.development)
        guard config.production != config.development else { throw GitFailure("Production and development branches must be different.") }
        let prefixes = GitFlowKind.allCases.map { config.prefix($0) }
        for prefix in prefixes {
            guard !prefix.isEmpty, prefix.hasSuffix("/"), !config.production.hasPrefix(prefix), !config.development.hasPrefix(prefix) else { throw GitFailure("Use non-empty topic prefixes ending in /, separate from base branches.") }
            try await validateReferenceName(prefix + "validation")
            guard !prefixes.contains(where: { $0 != prefix && ($0.hasPrefix(prefix) || prefix.hasPrefix($0)) }), prefixes.filter({ $0 == prefix }).count == 1 else { throw GitFailure("Git Flow topic prefixes must not overlap.") }
        }
        try await validateReferenceName(config.versionTag + "validation", tag: true)
    }
    func flowGuard() async throws -> GitFlowGuard {
        GitFlowGuard(head: try await headPosition(), refs: Dictionary(uniqueKeysWithValues: try await references().filter { $0.isLocal || $0.isTag }.map { ($0.fullName,$0.hash) }), config: try readLocalIndex(try await commonDirectory().appendingPathComponent("config")), index: try await submoduleAddIndex())
    }
    func requireFlowIdle() async throws {
        try await requireIdleManagement(); try await requireCleanHistoryWorktree()
        guard try await automaticStashRecord() == nil, try await activeGitFlow() == nil else { throw GitFailure("Finish saved automatic stash recovery or the active Git Flow operation first.") }
        guard try await headPosition().hash != nil else { throw GitFailure("Create an initial commit before enabling Git Flow.") }
    }
    func requireFlowBranchAvailable(_ name: String) async throws {
        if let ref = try await references().first(where: { $0.fullName == "refs/heads/" + name }) { try await requireBranchNotInOtherWorktree(ref, allowCurrent: true) }
    }
    public func previewGitFlowConfiguration(_ config: GitFlowConfiguration) async throws -> GitFlowPlan {
        try await requireFlowIdle(); try await validateFlowConfiguration(config)
        let before = try await flowGuard()
        guard let production = before.refs["refs/heads/" + config.production] else { throw GitFailure("Choose an existing local production branch.") }
        return GitFlowPlan(action: .configure, configuration: config, kind: .feature, name: "", branch: config.development, targets: [config.production, config.development], tag: nil, message: "", keepBranch: true, signTag: false, repository: root.path, before: before, source: production, remoteRef: nil)
    }
    public func previewGitFlowStart(_ kind: GitFlowKind, name: String, revision: String = "", tracking remoteRef: String? = nil) async throws -> GitFlowPlan {
        try await requireFlowIdle()
        guard let config = try await gitFlowConfiguration() else { throw GitFailure("Enable and configure Git Flow first.") }
        try await validateFlowConfiguration(config)
        let branch = config.prefix(kind) + name
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/") else { throw GitFailure("Enter a topic name.") }
        try await validateReferenceName(branch)
        let before = try await flowGuard()
        guard before.refs["refs/heads/" + branch] == nil else { throw GitFailure("The topic branch already exists.") }
        if kind == .release || kind == .hotfix {
            guard !before.refs.keys.contains(where: { $0.hasPrefix("refs/heads/" + config.prefix(kind)) }) else { throw GitFailure("Finish the existing release or hotfix before starting another of that kind.") }
        }
        let base = kind == .feature || kind == .release ? config.development : config.production
        if let remoteRef { guard remoteRef.hasPrefix("refs/remotes/"), try await references().contains(where: { $0.fullName == remoteRef && $0.isRemote }) else { throw GitFailure("Choose an existing remote tracking branch.") } }
        let source = try await verifiedCommit(remoteRef ?? (revision.isEmpty ? "refs/heads/" + base : revision))
        return GitFlowPlan(action: remoteRef == nil ? .start : .track, configuration: config, kind: kind, name: name, branch: branch, targets: [base,branch], tag: nil, message: "", keepBranch: true, signTag: false, repository: root.path, before: before, source: source, remoteRef: remoteRef)
    }
    public func previewGitFlowFinish(branch: String, keepBranch: Bool = false, tagMessage: String = "", signTag: Bool = false) async throws -> GitFlowPlan {
        try await requireFlowIdle()
        guard let config = try await gitFlowConfiguration(), let kind = config.kind(of: branch), kind != .support else { throw GitFailure("Choose a configured feature, release or hotfix branch. Support branches are long-lived.") }
        try await validateFlowConfiguration(config)
        let before = try await flowGuard()
        guard let source = before.refs["refs/heads/" + branch] else { throw GitFailure("The local topic branch is missing.") }
        let targets = kind == .feature ? [config.development] : [config.production, config.development]
        for name in targets + [branch] {
            guard before.refs["refs/heads/" + name] != nil else { throw GitFailure("A required Git Flow base branch is missing.") }
            try await requireFlowBranchAvailable(name)
        }
        let tag = kind == .feature ? nil : config.versionTag + String(branch.dropFirst(config.prefix(kind).count))
        if let tag { try await validateReferenceName(tag, tag: true); guard before.refs["refs/tags/" + tag] == nil else { throw GitFailure("The release tag already exists. Choose another version or inspect it first.") } }
        return GitFlowPlan(action: .finish, configuration: config, kind: kind, name: String(branch.dropFirst(config.prefix(kind).count)), branch: branch, targets: targets, tag: tag, message: tagMessage, keepBranch: keepBranch, signTag: signTag, repository: root.path, before: before, source: source, remoteRef: nil)
    }
}
