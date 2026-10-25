import Foundation

public struct FileRevision: Identifiable, Sendable {
    public var id: String { commit.hash }
    public let commit: Commit
    public let path: String
    public let previousPath: String?
    public let status: String
    public var isDeleted: Bool { status == "D" }
}

public struct FileHistory: Sendable {
    public let tip: String
    public let revisions: [FileRevision]
    public let hasMore: Bool
}

public struct BlameLine: Identifiable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let originalNumber: Int
    public let hash: String
    public let author: String
    public let email: String
    public let date: Date
    public let subject: String
    public let path: String
    public let text: String
}

public struct RevisionComparison: Sendable {
    public let left: String
    public let right: String
    public let files: [ChangedPath]
    public let statistics: [String: FileStatistics]
    public let originalPaths: [String: String]
}

extension GitRepository {
    public func fileHistory(path: String, revision: String = "HEAD", limit: Int = 500) async throws -> FileHistory {
        try validateInspectionPath(path)
        let tip = try await verifiedCommit(revision)
        let count = min(max(1, limit), 10_000)
        let output = try await GitProcess.run(["log", "--no-show-signature", "--follow", "--find-renames", "--max-count=\(count + 1)", "-z", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%D%x00", "--name-status", tip, "--", path], at: root)
        let revisions = try InspectionParser.fileHistory(output.data, path: path)
        return FileHistory(tip: tip, revisions: Array(revisions.prefix(count)), hasMore: revisions.count > count)
    }

    public func fileRevisionDiff(_ revision: FileRevision) async throws -> String {
        let paths = Array(Set([revision.path, revision.previousPath].compactMap { $0 })).sorted()
        for path in paths { try validateInspectionPath(path) }
        let hash = try await verifiedCommit(revision.commit.hash)
        let options = ["--no-ext-diff", "--no-textconv", "--unified=7", "--find-renames"]
        if let parent = revision.commit.parents.first {
            return try await GitProcess.run(["diff"] + options + [parent, hash, "--"] + paths, at: root).text
        }
        return try await GitProcess.run(["show", "--no-show-signature", "--format="] + options + [hash, "--"] + paths, at: root).text
    }

    public func blame(path: String, revision: String = "HEAD", ignoreWhitespace: Bool = false) async throws -> [BlameLine] {
        try validateInspectionPath(path)
        let hash = try await verifiedCommit(revision)
        // Validate the blob before invoking blame, which otherwise emits binary bytes as source lines.
        _ = try await inspectedFile(path: path, revision: hash)
        let output = try await GitProcess.run(["blame", "--line-porcelain"] + (ignoreWhitespace ? ["-w"] : []) + [hash, "--", path], at: root)
        return try InspectionParser.blame(output.data)
    }

    public func inspectedFile(path: String, revision: String) async throws -> String {
        try validateInspectionPath(path)
        let hash = try await verifiedCommit(revision)
        let output = try await GitProcess.run(["cat-file", "blob", hash + ":" + path], at: root)
        guard output.data.count <= 2_000_000, !output.data.contains(0), let text = String(data: output.data, encoding: .utf8) else {
            throw GitFailure("Text inspection supports UTF-8 files up to 2 MB. Binary and larger files cannot be displayed here.")
        }
        return text
    }

    public func compareRevisions(left: String, right: String, useMergeBase: Bool = false) async throws -> RevisionComparison {
        var lhs = try await verifiedCommit(left)
        let rhs = try await verifiedCommit(right)
        if useMergeBase { lhs = try await GitProcess.run(["merge-base", lhs, rhs], at: root).text.trimmingCharacters(in: .newlines) }
        let files = try await GitProcess.run(["diff", "--no-ext-diff", "--no-textconv", "--name-status", "--find-renames", "-z", lhs, rhs, "--"], at: root)
        let stats = try await GitProcess.run(["diff", "--no-ext-diff", "--no-textconv", "--numstat", "--find-renames", "-z", lhs, rhs, "--"], at: root)
        let fields = files.text.components(separatedBy: "\0")
        var originals: [String: String] = [:], index = 0
        while index + 1 < fields.count {
            let status = fields[index]; let path = fields[index + 1]; index += 2
            if status.hasPrefix("R") || status.hasPrefix("C"), index < fields.count { originals[fields[index]] = path; index += 1 }
        }
        return RevisionComparison(left: lhs, right: rhs, files: GitParser.changedPaths(files.data), statistics: GitParser.statistics(stats.data), originalPaths: originals)
    }

    public func comparisonDiff(_ comparison: RevisionComparison, path: String, context: Int = 7, ignoreWhitespace: Bool = false) async throws -> String {
        try validateInspectionPath(path)
        // Immutable hashes retain the preview even if either named branch moves.
        let left = try await verifiedCommit(comparison.left), right = try await verifiedCommit(comparison.right)
        let paths = Array(Set([path, comparison.originalPaths[path]].compactMap { $0 })).sorted()
        return try await GitProcess.run(["diff", "--no-ext-diff", "--no-textconv", "--find-renames", "--unified=\(min(max(context, 0), 100))"] + (ignoreWhitespace ? ["--ignore-all-space"] : []) + [left, right, "--"] + paths, at: root).text
    }

    nonisolated func validateInspectionPath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0), !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw GitFailure("Choose a file path relative to the repository root.")
        }
    }
}

enum InspectionParser {
    static func fileHistory(_ data: Data, path: String) throws -> [FileRevision] {
        guard let text = String(data: data, encoding: .utf8) else { throw GitFailure("The file history contains an unsupported filename encoding.") }
        let fields = text.components(separatedBy: "\0")
        var index = 0, currentPath = path
        var records: [FileRevision] = []
        while index < fields.count {
            while index < fields.count && fields[index].trimmingCharacters(in: .newlines).isEmpty { index += 1 }
            guard index < fields.count else { break }
            guard index + 6 < fields.count else { throw GitFailure("Incomplete file history metadata.") }
            let metadata = fields[index...index + 6].joined(separator: "\0") + "\0"
            guard let commit = GitParser.commits(Data(metadata.utf8)).first else { throw GitFailure("Unable to parse file history metadata.") }
            index += 7
            var status = "M", previous: String?
            while index < fields.count {
                let field = fields[index].trimmingCharacters(in: .newlines)
                if field.isEmpty { index += 1; continue }
                // Status tokens are at most a letter plus a similarity percentage; paths are consumed separately.
                guard let kind = field.first, "ACDMRTUXB".contains(kind), field.dropFirst().allSatisfy(\.isNumber) else { break }
                index += 1
                guard index < fields.count else { throw GitFailure("Incomplete file history path.") }
                let oldPath = fields[index]; index += 1
                var newPath = oldPath
                if kind == "R" || kind == "C" {
                    guard index < fields.count else { throw GitFailure("Incomplete file history rename.") }
                    newPath = fields[index]; index += 1
                }
                if newPath == currentPath {
                    status = field
                    if kind == "R" { previous = oldPath }
                }
            }
            records.append(FileRevision(commit: commit, path: currentPath, previousPath: previous, status: status))
            if let previous { currentPath = previous }
        }
        return records
    }

    static func blame(_ data: Data) throws -> [BlameLine] {
        guard let output = String(data: data, encoding: .utf8) else { throw GitFailure("Blame output is not valid UTF-8.") }
        let lines = output.components(separatedBy: "\n")
        var index = 0, result: [BlameLine] = []
        while index < lines.count {
            if lines[index].isEmpty { index += 1; continue }
            let header = lines[index].split(separator: " "); index += 1
            guard header.count >= 3, [40, 64].contains(header[0].count), let original = Int(header[1]), let number = Int(header[2]) else { throw GitFailure("Unable to parse blame line header.") }
            var metadata: [String: String] = [:], source: String?
            while index < lines.count {
                let line = lines[index]; index += 1
                if line.hasPrefix("\t") { source = String(line.dropFirst()); break }
                let value = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                if value.count == 2 { metadata[String(value[0])] = String(value[1]) }
            }
            guard let source else { throw GitFailure("Incomplete blame source line.") }
            result.append(BlameLine(number: number, originalNumber: original, hash: String(header[0]), author: metadata["author"] ?? "", email: metadata["author-mail"] ?? "", date: Date(timeIntervalSince1970: Double(metadata["author-time"] ?? "") ?? 0), subject: metadata["summary"] ?? "", path: decodeGitPath(metadata["filename"] ?? ""), text: source))
        }
        return result
    }

    // Git quotes unusual filenames in line-porcelain, using octal UTF-8 bytes.
    static func decodeGitPath(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        let source = Array(value.utf8.dropFirst().dropLast()), escapes: [UInt8: UInt8] = [110: 10, 116: 9, 114: 13, 98: 8, 102: 12, 118: 11, 97: 7, 34: 34, 92: 92]
        var bytes: [UInt8] = [], i = 0
        while i < source.count {
            if source[i] == 92, i + 1 < source.count {
                i += 1
                if source[i] >= 48 && source[i] <= 55 {
                    var value = 0, count = 0
                    while i < source.count && count < 3 && source[i] >= 48 && source[i] <= 55 { value = value * 8 + Int(source[i] - 48); i += 1; count += 1 }
                    bytes.append(UInt8(truncatingIfNeeded: value)); continue
                }
                bytes.append(escapes[source[i]] ?? source[i]); i += 1
            } else { bytes.append(source[i]); i += 1 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
