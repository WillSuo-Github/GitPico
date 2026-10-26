import Foundation
import CryptoKit

public struct HistoryRevision: Sendable {
    public let identity: String
    let hashes: [String]
    public static func reference(_ name: String, hash: String) -> Self { Self(identity: name + ":" + hash, hashes: [hash]) }
    public static func all(references: [Reference], head: HeadPosition) -> Self {
        let signature = references.sorted { $0.fullName < $1.fullName }.map { $0.fullName + ":" + $0.hash + ($0.isCurrent ? ":HEAD" : "") }.joined(separator: "\n") + "\n" + head.branch + ":" + (head.hash ?? "")
        let identity = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self(identity: identity, hashes: Array(Set(references.map(\.hash) + [head.hash].compactMap { $0 })).sorted())
    }
}
public struct CommitHistoryPage: Sendable {
    public let commits: [Commit]
    public let hasMore: Bool
    public let totalCount: Int?
    public init(commits: [Commit], hasMore: Bool, totalCount: Int? = nil) { self.commits = commits; self.hasMore = hasMore; self.totalCount = totalCount }
}
extension GitRepository {
    public func resolveHistory(_ reference: String?) async throws -> HistoryRevision {
        if let reference {
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
        return CommitHistoryPage(commits: Array(commits.prefix(options.limit)), hasMore: hasMore, totalCount: hasMore ? nil : commits.count)
    }
}
