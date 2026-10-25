import Foundation

public struct WorkingFileEntry: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let change: FileChange?
    public let isTracked: Bool
    public let isIgnored: Bool
    public let assumeUnchanged: Bool
    public let skipWorktree: Bool
    public init(path: String, change: FileChange?, isTracked: Bool, isIgnored: Bool, assumeUnchanged: Bool, skipWorktree: Bool) {
        self.path = path; self.change = change; self.isTracked = isTracked; self.isIgnored = isIgnored; self.assumeUnchanged = assumeUnchanged; self.skipWorktree = skipWorktree
    }
    public var status: String { change?.displayStatus ?? (isIgnored ? "Ignored" : skipWorktree ? "Skip Worktree" : assumeUnchanged ? "Assume Unchanged" : "Unmodified") }
}

extension GitRepository {
    public func workingFiles(includeIgnored: Bool = false, limit: Int = 50_000) async throws -> [WorkingFileEntry] {
        async let trackedOutput = GitProcess.run(["ls-files", "-v", "-z", "--cached", "--"], at: root)
        async let untrackedOutput = GitProcess.run(["ls-files", "--others", "--exclude-standard", "-z", "--"], at: root)
        async let statusOutput = GitProcess.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root)
        let (tracked, untracked, status) = try await (trackedOutput, untrackedOutput, statusOutput)
        func names(_ data: Data) throws -> [String] {
            guard let value = String(data: data, encoding: .utf8) else { throw GitFailure("File browsing requires UTF-8 filenames.") }
            return value.components(separatedBy: "\0").filter { !$0.isEmpty }
        }
        let changes = GitParser.status(status.data)
        var flags: [String: Character] = [:]
        for record in try names(tracked.data) {
            guard record.count >= 3, let flag = record.first else { throw GitFailure("Invalid tracked-file entry.") }
            flags[String(record.dropFirst(2))] = flag
        }
        var paths = Set(flags.keys); paths.formUnion(try names(untracked.data)); paths.formUnion(changes.map(\.path))
        let ignored: Set<String> = includeIgnored ? Set(try names(try await GitProcess.run(["ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--"], at: root).data)) : []
        paths.formUnion(ignored)
        guard paths.count <= min(max(limit, 1), 100_000) else { throw GitFailure("The working file list exceeds its entry limit. Use a smaller working tree.") }
        let byPath = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
            WorkingFileEntry(path: path, change: byPath[path], isTracked: flags[path] != nil, isIgnored: ignored.contains(path), assumeUnchanged: flags[path]?.isLowercase == true, skipWorktree: flags[path].map { String($0).uppercased() == "S" } ?? false)
        }
    }
    public func workingFileData(_ path: String) throws -> Data {
        guard let file = try localFiles([path]).first, let data = file.data else { throw GitFailure("The file is missing. Refresh the working copy.") }
        return data
    }
    public func previewForceAddIgnored(_ paths: [String]) async throws -> LocalChangePlan {
        let files = try await workingFiles(includeIgnored: true), chosen = paths.sorted()
        guard !chosen.isEmpty, Set(chosen).count == chosen.count, chosen.allSatisfy({ path in files.contains { $0.path == path && $0.isIgnored } }) else { throw GitFailure("Select only files that are currently ignored by Git.") }
        try await requireLocalChangeSupport(chosen)
        let head = try await headPosition(), index = try readLocalIndex(try await localIndexURL()), before = try localFiles(chosen)
        let directory = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let temporaryIndex = try await scratchIndex(index, in: directory)
        _ = try await GitProcess.run(["add", "--force", "--"] + chosen, at: root, indexFile: temporaryIndex)
        return LocalChangePlan(id: UUID(), title: "Force Add Ignored Files", paths: chosen, preview: "Ignored files will become tracked in the index:\n\n" + chosen.joined(separator: "\n"), repository: root.path, head: head, beforeIndex: index, afterIndex: try readLocalIndex(temporaryIndex), before: before, after: before)
    }
}
