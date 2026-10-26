import Foundation
import Darwin

public enum BinaryFileSource: Sendable, Equatable {
    case workingCopy, index, revision(String), empty
    public var title: String {
        switch self { case .workingCopy: "Working Copy"; case .index: "Index"; case .revision(let value): String(value.prefix(12)); case .empty: "Absent" }
    }
}
public struct BinaryComparison: Sendable {
    public let left: Data?
    public let right: Data?
}

extension GitRepository {
    public func binaryComparison(path: String, originalPath: String? = nil, left: BinaryFileSource, right: BinaryFileSource) async throws -> BinaryComparison {
        var previousPath = originalPath ?? path
        if originalPath == nil, case .revision(let lhs) = left, case .revision(let rhs) = right {
            previousPath = try await compareRevisions(left: lhs, right: rhs).originalPaths[path] ?? path
        }
        async let before = binaryFile(path: previousPath, source: left)
        async let after = binaryFile(path: path, source: right)
        return try await BinaryComparison(left: before, right: after)
    }
    private func binaryFile(path: String, source: BinaryFileSource) async throws -> Data? {
        try validateInspectionPath(path)
        guard !path.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) else { throw GitFailure("Git administrative files cannot be previewed.") }
        let maximum = 16 * 1024 * 1024
        if source == .empty { return nil }
        if source == .workingCopy {
            let file = root.appendingPathComponent(path)
            let resolved = file.deletingLastPathComponent().resolvingSymlinksInPath().path
            guard resolved == root.path || resolved.hasPrefix(root.path + "/") else { throw GitFailure("File preview cannot follow a directory outside the repository.") }
            let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if descriptor < 0, errno == ENOENT { return nil }
            guard descriptor >= 0 else { throw GitFailure("The working file cannot be opened safely.") }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximum else { throw GitFailure("Preview supports regular files up to 16 MB.") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let data = try handle.read(upToCount: maximum + 1) ?? Data()
            guard data.count <= maximum else { throw GitFailure("The file grew beyond the preview limit.") }
            return data
        }
        let fields: [Substring]
        switch source {
        case .revision(let revision):
            let hash = try await verifiedCommit(revision)
            let tree = try await GitProcess.run(["ls-tree", "-z", "--full-tree", hash, "--", path], at: root).text
            guard let record = tree.split(separator: "\0").first(where: { $0.split(separator: "\t", maxSplits: 1).last == Substring(path) }) else { return nil }
            fields = record.split(separator: "\t", maxSplits: 1)[0].split(separator: " ")
        case .index:
            let index = try await GitProcess.run(["ls-files", "--stage", "-z", "--", path], at: root).text
            guard let record = index.split(separator: "\0").first(where: { $0.split(separator: "\t", maxSplits: 1).last == Substring(path) }) else { return nil }
            fields = record.split(separator: "\t", maxSplits: 1)[0].split(separator: " ")
            guard fields.count == 3, fields[2] == "0" else { throw GitFailure("Resolve the conflicted index before comparing this file.") }
        case .workingCopy, .empty: return nil
        }
        guard fields.count == 3, ["100644", "100755", "120000"].contains(String(fields[0])) else { throw GitFailure("This tree entry is not a previewable file.") }
        let object = String(fields[source == .index ? 1 : 2])
        let size = Int(try await GitProcess.run(["cat-file", "-s", object], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Int.max
        guard size <= maximum else { throw GitFailure("Preview supports files up to 16 MB.") }
        return try await GitProcess.run(["cat-file", "blob", object], at: root, maxOutputBytes: maximum, cancellable: true).data
    }
}
