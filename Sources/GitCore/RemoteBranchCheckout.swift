import Foundation

public enum RemoteBranchCheckoutTarget: Equatable, Sendable {
    case existing(Reference)
    case create(String)
    case chooseName

    public static func resolve(_ remote: Reference, references: [Reference], remotes: [String]) throws -> Self {
        guard remote.isRemote,
              let remoteName = remotes.sorted(by: { $0.count > $1.count }).first(where: { remote.name.hasPrefix($0 + "/") }) else {
            throw GitFailure("Choose a configured remote branch.")
        }
        let name = String(remote.name.dropFirst(remoteName.count + 1))
        guard !name.isEmpty, name != "HEAD" else { throw GitFailure("Choose a remote branch, not the remote HEAD.") }
        let locals = references.filter(\.isLocal)
        let fullNames = Set(references.map(\.fullName))
        let tracking = locals.filter { local in
            guard !local.upstream.isEmpty else { return false }
            // Git qualifies upstream:short when a tag or local branch makes its usual short name ambiguous.
            let candidates = Set([local.upstream, "refs/" + local.upstream, "refs/heads/" + local.upstream,
                                  "refs/tags/" + local.upstream, "refs/remotes/" + local.upstream]).intersection(fullNames)
            return candidates == [remote.fullName]
        }
        if let sameName = tracking.first(where: { $0.name == name }) { return .existing(sameName) }
        if tracking.count == 1 { return .existing(tracking[0]) }
        if tracking.count > 1 || locals.contains(where: { $0.name == name }) { return .chooseName }
        return .create(name)
    }
}

extension GitRepository {
    public func switchRemoteBranch(_ reference: Reference, target: RemoteBranchCheckoutTarget) async throws {
        try await requireIdleManagement()
        try await requireReference(reference)
        let currentTarget = try await RemoteBranchCheckoutTarget.resolve(reference, references: references(), remotes: remoteConfigurations().map(\.name))
        guard currentTarget == target else { throw GitFailure("This reference changed outside the preview. Refresh before continuing.") }
        switch target {
        case .existing(let local):
            try await switchBranch(local)
        case .create(let name):
            try await validateReferenceName(name)
            // One Git switch creates both the branch and its tracking configuration only if checkout succeeds.
            _ = try await GitProcess.run(["switch", "--track=direct", "-c", name, "--", reference.fullName], at: root)
        case .chooseName:
            throw GitFailure("A local branch with this name already exists. Choose a different name.")
        }
    }
}
