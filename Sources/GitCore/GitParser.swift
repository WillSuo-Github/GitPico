import Foundation

public enum GitParser {
    public static func statistics(_ data: Data) -> [String: FileStatistics] {
        let fields = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
        var result: [String: FileStatistics] = [:]
        var index = 0
        while index < fields.count {
            let fieldsForFile = fields[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            index += 1
            guard fieldsForFile.count == 3 else { continue }
            var path = String(fieldsForFile[2])
            if path.isEmpty, index + 1 < fields.count {
                path = String(fields[index + 1]); index += 2
            }
            result[path] = FileStatistics(additions: Int(fieldsForFile[0]) ?? 0, deletions: Int(fieldsForFile[1]) ?? 0, isBinary: fieldsForFile[0] == "-")
        }
        return result
    }

    public static func status(_ data: Data) -> [FileChange] {
        let fields = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
        var result: [FileChange] = []
        var i = 0
        while i < fields.count {
            let record = fields[i]
            i += 1
            guard record.count >= 4 else { continue }
            let codes = Array(record.prefix(2))
            let path = String(record.dropFirst(3))
            var original: String?
            if codes.contains("R") || codes.contains("C") {
                if i < fields.count { original = String(fields[i]); i += 1 }
            }
            result.append(FileChange(path: path, originalPath: original, index: codes[0], worktree: codes[1]))
        }
        return result
    }

    public static func commits(_ data: Data) -> [Commit] {
        let fields = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
        var result: [Commit] = []
        var i = 0
        while i + 6 < fields.count {
            let hash = fields[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard hash.count == 40 || hash.count == 64 else { break }
            result.append(Commit(
                hash: hash, parents: fields[i + 1].split(separator: " ").map(String.init),
                author: String(fields[i + 2]), email: String(fields[i + 3]),
                date: Date(timeIntervalSince1970: Double(fields[i + 4]) ?? 0),
                subject: String(fields[i + 5]),
                decorations: fields[i + 6].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            ))
            i += 7
        }
        return result
    }

    public static func references(_ data: Data) -> [Reference] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard f.count == 5 else { return nil }
            let full = String(f[0])
            let prefix = ["refs/heads/", "refs/remotes/", "refs/tags/"].first(where: full.hasPrefix) ?? ""
            return Reference(fullName: full, name: String(full.dropFirst(prefix.count)), hash: String(f[1]), upstream: String(f[3]), isCurrent: f[4] == "*")
        }
    }

    public static func changedPaths(_ data: Data) -> [ChangedPath] {
        let f = String(decoding: data, as: UTF8.self).split(separator: "\0")
        var result: [ChangedPath] = []
        var i = 0
        while i + 1 < f.count {
            let status = String(f[i]); i += 1
            var path = String(f[i]); i += 1
            if (status.hasPrefix("R") || status.hasPrefix("C")), i < f.count {
                path = String(f[i]); i += 1
            }
            result.append(ChangedPath(status: status, path: path))
        }
        return result
    }
}
