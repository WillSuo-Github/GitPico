import Foundation
import CryptoKit

public struct HistoryRevision: Sendable {
    public let identity: String
    let hashes: [String]
    let trackingLocalTip: String?
    public static func reference(_ name: String, hash: String) -> Self {
        Self(identity: name + ":" + hash, hashes: [hash], trackingLocalTip: nil)
    }
    static func trackingBranch(_ name: String, hash: String, upstream: String, upstreamHash: String) -> Self {
        Self(identity: "\(name):\(hash)\n\(upstream):\(upstreamHash)", hashes: hash == upstreamHash ? [hash] : [hash, upstreamHash],
             trackingLocalTip: hash == upstreamHash ? nil : hash)
    }
    public static func all(references: [Reference], head: HeadPosition) -> Self {
        let signature = references.sorted { $0.fullName < $1.fullName }.map { $0.fullName + ":" + $0.hash + ($0.isCurrent ? ":HEAD" : "") }.joined(separator: "\n") + "\n" + head.branch + ":" + (head.hash ?? "")
        let identity = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self(identity: identity, hashes: Array(Set(references.map(\.hash) + [head.hash].compactMap { $0 })).sorted(),
                    trackingLocalTip: nil)
    }
}
public struct CommitHistoryPage: Sendable {
    public let commits: [Commit]
    public let hasMore: Bool
    public let totalCount: Int?
    public let incomingHashes: Set<String>
    public init(commits: [Commit], hasMore: Bool, totalCount: Int? = nil, incomingHashes: Set<String> = []) {
        self.commits = commits; self.hasMore = hasMore; self.totalCount = totalCount; self.incomingHashes = incomingHashes
    }
}
extension GitRepository {
    public func resolveHistory(_ reference: String?) async throws -> HistoryRevision {
        if let reference {
            // Sidebar selections use full ref names. Keep tags, remote refs, and
            // arbitrary revision expressions scoped to the selected commit.
            if reference.hasPrefix("refs/heads/") {
                let branch = try await GitProcess.run(["for-each-ref", "--count=1", "--format=%(refname)%00%(objectname)%00%(upstream)", "--", reference], at: root, cancellable: true)
                let fields = branch.text.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
                if fields.count == 3, fields[0] == reference {
                    let hash = fields[1], upstream = fields[2]
                    if !upstream.isEmpty {
                        let tip = try await GitProcess.run(["rev-parse", "--verify", "--quiet", "--end-of-options", upstream + "^{commit}"], at: root, allowed: [0, 1, 128], cancellable: true)
                        if tip.status == 0 {
                            return .trackingBranch(reference, hash: hash, upstream: upstream, upstreamHash: tip.text.trimmingCharacters(in: .newlines))
                        }
                    }
                    return .reference(reference, hash: hash)
                }
            }
            let result = try await GitProcess.run(["rev-parse", "--verify", "--quiet", "--end-of-options", reference + "^{commit}"], at: root, allowed: [0,1,128], cancellable: true)
            guard result.status == 0 else { throw GitFailure("This revision is no longer available. Refresh the repository references.") }
            return .reference(reference, hash: result.text.trimmingCharacters(in: .newlines))
        }
        async let refs = GitProcess.run(["for-each-ref", "--sort=refname", "--format=%(refname)%00%(objectname)%00%(symref)%00%(upstream:short)%00%(HEAD)", "refs/heads", "refs/remotes", "refs/tags"], at: root, cancellable: true)
        async let hash = GitProcess.run(["rev-parse", "--verify", "--quiet", "HEAD"], at: root, allowed: [0,1], cancellable: true)
        let references = GitParser.references(try await refs.data), head = try await hash
        let position = HeadPosition(branch: references.first(where: \.isCurrent)?.fullName ?? "HEAD", hash: head.status == 0 ? head.text.trimmingCharacters(in: .newlines) : nil)
        return .all(references: references, head: position)
    }
    public func historyPage(at revision: HistoryRevision, options: HistoryOptions = HistoryOptions()) async throws -> CommitHistoryPage {
        guard (1...20_000).contains(options.limit), revision.hashes.allSatisfy({ [40,64].contains($0.count) && $0.allSatisfy(\.isHexDigit) }) else { throw GitFailure("Invalid history revision or page size.") }
        guard !revision.hashes.isEmpty else { return CommitHistoryPage(commits: [], hasMore: false, totalCount: 0) }
        let query = try HistoryQuery(options.query)
        var tips = revision.hashes
        if let prefix = query.hash {
            let resolved = try await GitProcess.run(["rev-parse", "--verify", "--quiet", prefix + "^{commit}"], at: root, allowed: [0, 1, 128], cancellable: true)
            guard resolved.status == 0 else { return CommitHistoryPage(commits: [], hasMore: false) }
            let hash = resolved.text.trimmingCharacters(in: .newlines)
            // A hash query must remain within the selected branch/reference scope.
            let containing = try await GitProcess.run(["rev-list", "--max-count=1", "--ancestry-path=" + hash, "--stdin"], at: root, input: Data((tips.joined(separator: "\n") + "\n^" + hash + "\n").utf8), cancellable: true)
            guard tips.contains(hash) || !containing.data.isEmpty else { return CommitHistoryPage(commits: [], hasMore: false) }
            tips = [hash]
        }
        let filters = (query.hash == nil ? [] : ["--no-walk=unsorted"]) + (options.firstParent ? ["--first-parent"] : []) + query.arguments
        let args = ["log", "--no-show-signature", options.sortByDate ? "--date-order" : "--topo-order", "--max-count=\(query.hash == nil ? options.limit + 1 : 1)", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%D%x00"] + filters + ["--stdin", "--"] + query.paths
        let output = try await GitProcess.run(args, at: root, input: Data((tips.joined(separator: "\n") + "\n").utf8), cancellable: true)
        let commits = GitParser.commits(output.data), hasMore = commits.count > options.limit
        let visible = Array(commits.prefix(options.limit))
        let incoming = try await incomingHistoryHashes(visible, excluding: revision.trackingLocalTip)
        return CommitHistoryPage(commits: visible, hasMore: hasMore, totalCount: hasMore ? nil : commits.count, incomingHashes: incoming)
    }

    private func incomingHistoryHashes(_ commits: [Commit], excluding localTip: String?) async throws -> Set<String> {
        guard let localTip, !commits.isEmpty else { return [] }
        let visible = Set(commits.map(\.hash))
        // The page contains commits reachable from either tip. Remove everything
        // reachable from the local tip, regardless of sort order or search filters.
        let input = commits.map(\.hash).joined(separator: "\n") + "\n^" + localTip + "\n"
        do {
            let output = try await GitProcess.run(["rev-list", "--stdin"], at: root, input: Data(input.utf8), cancellable: true)
            return Set(output.text.split(separator: "\n").lazy.map(String.init).filter { visible.contains($0) })
        } catch let failure as GitFailure where failure.reason == .outputLimitExceeded {
            // A very old filtered page can be separated from the local tip by
            // more history than fits in a bounded process result.
            var incoming: Set<String> = []
            for commit in commits {
                let result = try await GitProcess.run(["merge-base", "--is-ancestor", commit.hash, localTip],
                                                      at: root, allowed: [0, 1], cancellable: true)
                if result.status == 1 { incoming.insert(commit.hash) }
            }
            return incoming
        }
    }
}
