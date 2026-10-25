import Foundation

extension GitRepository {
    public func reflog(ref: String = "HEAD", limit: Int = 500) async throws -> [ReflogEntry] {
        guard ref == "HEAD" || ref.hasPrefix("refs/") else { throw GitFailure("Choose HEAD or a full reference name.") }
        let exists = try await GitProcess.run(["reflog", "exists", ref], at: root, allowed: [0, 1])
        guard exists.status == 0 else { return [] }
        let output = try await GitProcess.run(["reflog", "show", "--max-count=\(max(1, min(limit, 10000)))", "--date=raw", "--format=%H%x00%gD%x00%gs%x00%gn%x00%ge%x00", ref, "--"], at: root)
        let values = output.text.components(separatedBy: "\0")
        var entries: [ReflogEntry] = []
        var offset = 0
        while offset + 4 < values.count {
            let hash = values[offset].trimmingCharacters(in: .newlines)
            let selector = values[offset + 1]
            let epoch = selector.components(separatedBy: "@{").last?.split(separator: " ").first.flatMap { Double($0) } ?? 0
            entries.append(ReflogEntry(selector: "\(ref)@{\(entries.count)}", hash: hash, message: values[offset + 2], name: values[offset + 3], email: values[offset + 4], date: Date(timeIntervalSince1970: epoch)))
            offset += 5
        }
        return entries
    }

    public func commit(at revision: String) async throws -> Commit {
        let hash = try await verifiedCommit(revision)
        let data = try await GitProcess.run(["show", "--no-show-signature", "-s", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%D%x00", hash, "--"], at: root).data
        guard let commit = GitParser.commits(data).first else { throw GitFailure("Unable to load the selected commit.") }
        return commit
    }
}
