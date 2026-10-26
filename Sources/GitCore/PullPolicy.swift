import Foundation

public enum PullPolicy: Int, Codable, CaseIterable, Sendable {
    case fastForwardOnly, merge, rebase
    public var title: String {
        switch self {
        case .fastForwardOnly: "Fast-forward only"
        case .merge: "Merge"
        case .rebase: "Rebase"
        }
    }
    public var explanation: String {
        switch self {
        case .fastForwardOnly: "Update only when no local commits need integrating. Divergence stops safely."
        case .merge: "Preserve local commit hashes. Create a merge commit when the branches diverge."
        case .rebase: "Replay local commits on top of the upstream branch. Local commit hashes change."
        }
    }
}

extension GitRepository {
    func upstreamDivergence() async throws -> (Int, Int) {
        // A configured upstream may have been deleted or may not have been fetched yet.
        let upstream = try await GitProcess.run(["rev-parse", "--verify", "--quiet", "@{upstream}^{commit}"], at: root, allowed: [0, 1, 128])
        guard upstream.status == 0 else { return (0, 0) }
        let hash = upstream.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let counts = try await GitProcess.run(["rev-list", "--left-right", "--count", "HEAD..." + hash, "--"], at: root).text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.count == 2 else { throw GitFailure("Unable to read upstream divergence.") }
        return (counts[0], counts[1])
    }

    public func pull(policy: PullPolicy, expectedHead: HeadPosition? = nil, expectedUpstream: String? = nil) async throws {
        let before = try await headPosition()
        if let expectedHead, before != expectedHead { throw GitFailure("HEAD changed since Pull was reviewed. Review the current branch again.") }
        if let expectedUpstream {
            let current = try await references().first(where: \.isCurrent)?.upstream ?? ""
            guard current == expectedUpstream else { throw GitFailure("The tracking branch changed since Pull was reviewed. Review the current upstream again.") }
        }
        guard before.hash != nil, try await currentOperation() == .none else { throw GitFailure("Finish the current integration before pulling.") }
        let flags: [String]
        switch policy {
        case .fastForwardOnly: flags = ["--no-rebase", "--ff-only", "--no-autostash"]
        case .merge: flags = ["--no-rebase", "--ff", "--no-edit", "--no-autostash"]
        case .rebase: flags = ["--rebase", "--no-autostash"]
        }
        _ = try await GitProcess.run(["pull"] + flags, at: root, timeout: 120)
        if try await headPosition() != before {
            do { try await recordHistory(before, title: "Pull (" + policy.title + ")", restoresFiles: false) }
            catch { throw GitFailure("Pull completed, but its Undo record could not be saved. Inspect History or Reflog before another operation. " + error.localizedDescription) }
        }
    }
}
