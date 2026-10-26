import Foundation

extension GitRepository {
    public func fileHistoryAcrossReferences(path: String, revision: String = "HEAD", limit: Int = 500) async throws -> FileHistory {
        try validateInspectionPath(path)
        let tip = try await verifiedCommit(revision)
        let hashes = try await resolveHistory(nil).hashes
        guard hashes.count <= 256 else { throw GitFailure("All-reference file history supports up to 256 distinct tips. Select a specific revision for larger reference sets.") }
        let maximum = min(max(1, limit), 10_000)
        var aliases = [path], processed: Set<String> = [], revisions: [String: FileRevision] = [:], truncated = false
        var index = 0
        while index < aliases.count {
            let name = aliases[index]; index += 1
            for hash in hashes {
                try Task.checkCancellation()
                let key = hash + "\0" + name
                guard processed.insert(key).inserted else { continue }
                guard processed.count <= 1024 else { throw GitFailure("This renamed file spans too many tips and names. Select a specific revision to narrow its history.") }
                let history = try await fileHistory(path: name, revision: hash, limit: maximum)
                truncated = truncated || history.hasMore
                for entry in history.revisions {
                    if revisions[entry.id] == nil || entry.path == path { revisions[entry.id] = entry }
                    for alias in [entry.path, entry.previousPath].compactMap({ $0 }) where !aliases.contains(alias) {
                        guard aliases.count < 32 else { throw GitFailure("This file exceeds the 32-name rename history limit. Select a specific revision.") }
                        aliases.append(alias)
                    }
                }
            }
        }
        let ordered = revisions.values.sorted { $0.commit.date == $1.commit.date ? $0.commit.hash > $1.commit.hash : $0.commit.date > $1.commit.date }
        return FileHistory(tip: tip, revisions: Array(ordered.prefix(maximum)), hasMore: truncated || ordered.count > maximum)
    }
}
