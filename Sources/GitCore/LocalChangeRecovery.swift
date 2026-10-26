import Darwin
import Foundation

public enum DiscardScope: String, CaseIterable, Sendable {
    case unstaged, allLocal
    public var title: String { self == .unstaged ? "Unstaged Changes Only" : "Staged and Unstaged Changes" }
}

struct LocalFileState: Codable, Equatable, Sendable {
    let path: String
    let data: Data?
    let permissions: Int?
    var symbolicLink: String? = nil
    var directory: Bool? = nil
}

public struct LocalChangePlan: Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let paths: [String]
    public let preview: String
    let repository: String
    let head: HeadPosition
    let beforeIndex: Data?
    let afterIndex: Data?
    let before: [LocalFileState]
    let after: [LocalFileState]
}

public struct LocalChangeBackup: Codable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let date: Date
    public var paths: [String] { before.map(\.path) }
    public private(set) var state: String
    let repository: String
    let head: HeadPosition
    let beforeIndex: Data?
    let afterIndex: Data?
    let before: [LocalFileState]
    let after: [LocalFileState]

    init(_ plan: LocalChangePlan) {
        id = plan.id; title = plan.title; date = Date(); state = "prepared"
        repository = plan.repository; head = plan.head
        beforeIndex = plan.beforeIndex; afterIndex = plan.afterIndex
        before = plan.before; after = plan.after
    }
    mutating func mark(_ value: String) { state = value }
}

extension GitRepository {
    func localIndexURL() async throws -> URL {
        let path = try await GitProcess.run(["rev-parse", "--path-format=absolute", "--git-path", "index"], at: root).text.trimmingCharacters(in: .newlines)
        return URL(fileURLWithPath: path)
    }

    nonisolated func localAttributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let value = error as NSError
            if value.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(value.code) { return nil }
            if value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT) { return nil }
            throw error
        }
    }

    nonisolated func readLocalIndex(_ url: URL) throws -> Data? {
        guard let attributes = try localAttributes(url) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 32 * 1024 * 1024 else {
            throw GitFailure("The index is not a regular file or exceeds 32 MB.")
        }
        return try Data(contentsOf: url)
    }

    func validateLocalPath(_ path: String, in directory: URL? = nil, allowLeafLink: Bool = false) throws -> URL {
        try validateInspectionPath(path)
        let components = path.components(separatedBy: "/")
        guard components.allSatisfy({ !$0.isEmpty && $0.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) != ".git" }) else {
            throw GitFailure("Patches and recovery cannot change Git administrative paths.")
        }
        let base = directory ?? root
        var url = base
        for (index, component) in components.enumerated() {
            url.appendPathComponent(component)
            if let attributes = try localAttributes(url) {
                let type = attributes[.type] as? FileAttributeType
                guard (type != .typeSymbolicLink || (allowLeafLink && index == components.count - 1)), index == components.count - 1 || type == .typeDirectory else {
                    throw GitFailure("A path contains a symbolic link or a non-directory parent: \(path)")
                }
            }
        }
        return url
    }

    func localFiles(_ paths: [String], in directory: URL? = nil) throws -> [LocalFileState] {
        var total = 0
        return try paths.map { path in
            let url = try validateLocalPath(path, in: directory, allowLeafLink: true)
            guard let attributes = try localAttributes(url) else {
                return LocalFileState(path: path, data: nil, permissions: nil)
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                guard !target.isEmpty, target.utf8.count <= 4096, !target.utf8.contains(0) else { throw GitFailure("Invalid symbolic-link target: " + path) }
                return LocalFileState(path: path, data: nil, permissions: nil, symbolicLink: target)
            }
            if attributes[.type] as? FileAttributeType == .typeDirectory { return LocalFileState(path: path, data: nil, permissions: nil, directory: true) }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.referenceCount] as? NSNumber)?.intValue ?? 1 <= 1 else {
                throw GitFailure("Local change recovery supports regular files, not directories, links or submodules: \(path)")
            }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
            guard size <= 16 * 1024 * 1024, total <= 32 * 1024 * 1024 - size else {
                throw GitFailure("Recovery is limited to 16 MB per file and 32 MB per selection. Narrow the selection.")
            }
            let data = try Data(contentsOf: url); total += data.count
            return LocalFileState(path: path, data: data, permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue)
        }
    }

    func writeLocalFile(_ state: LocalFileState, in directory: URL? = nil) throws {
        let url = try validateLocalPath(state.path, in: directory, allowLeafLink: true)
        guard state.directory != true, try localAttributes(url)?[.type] as? FileAttributeType != .typeDirectory else { throw GitFailure("Patch and recovery operations preserve submodule directories. Update them separately.") }
        if let target = state.symbolicLink {
            guard state.data == nil, !target.isEmpty, target.utf8.count <= 4096, !target.utf8.contains(0) else { throw GitFailure("Invalid symbolic-link recovery record.") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".gitpico-link-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: target)
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw GitFailure("Unable to install the symbolic link: " + state.path) }
            return
        }
        if let data = state.data {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".gitpico-" + UUID().uuidString)
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw GitFailure("Unable to prepare a replacement for " + state.path) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
            try handle.write(contentsOf: data); try handle.synchronize()
            try FileManager.default.setAttributes([.posixPermissions: state.permissions ?? 0o644], ofItemAtPath: temporary.path)
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw GitFailure("Unable to replace " + state.path) }
        } else if try localAttributes(url) != nil { try FileManager.default.removeItem(at: url) }
    }

    func validateLocalStates(_ before: [LocalFileState], _ after: [LocalFileState]) throws {
        guard !before.isEmpty, before.count <= 512, before.map(\.path) == after.map(\.path), Set(before.map(\.path)).count == before.count else {
            throw GitFailure("Invalid local recovery file records.")
        }
        for states in [before, after] {
            guard states.allSatisfy({ state in
                (state.symbolicLink == nil || (state.data == nil && state.directory != true && !state.symbolicLink!.isEmpty && state.symbolicLink!.utf8.count <= 4096 && !state.symbolicLink!.utf8.contains(0))) && (state.directory != true || (state.data == nil && state.symbolicLink == nil))
            }) else { throw GitFailure("Invalid structural recovery state.") }
            guard states.allSatisfy({ ($0.data?.count ?? 0) <= 16 * 1024 * 1024 }),
                  states.reduce(0, { $0 + ($1.data?.count ?? 0) }) <= 32 * 1024 * 1024 else { throw GitFailure("Recovery exceeds the 16 MB file or 32 MB selection limit.") }
        }
    }

    func requireLocalChangeSupport(_ paths: [String], allowStructural: Bool = false) async throws {
        guard !paths.isEmpty, paths.count <= 512, Set(paths.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == paths.count else {
            throw GitFailure("Choose between 1 and 512 distinct file paths without case aliases.")
        }
        try await requireIdleManagement()
        for path in paths {
            let url = try validateLocalPath(path, allowLeafLink: allowStructural)
            if !allowStructural, let attributes = try localAttributes(url) {
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw GitFailure("Choose regular files for this operation: " + path) }
            }
            guard !paths.contains(where: { $0 != path && $0.hasPrefix(path + "/") }) else { throw GitFailure("Select paths without nested destinations for patch/recovery operations.") }
        }
        let shared = try await GitProcess.run(["rev-parse", "--shared-index-path"], at: root).text.trimmingCharacters(in: .newlines)
        guard shared.isEmpty else { throw GitFailure("Disable the split index before using local change recovery.") }
        let sparse = try await GitProcess.run(["config", "--bool", "core.sparseCheckout"], at: root, allowed: [0, 1])
        guard sparse.text.trimmingCharacters(in: .newlines) != "true" else { throw GitFailure("Expand the sparse checkout before discarding or importing patches.") }
        let entries = try await GitProcess.run(["ls-files", "--stage", "-z", "--"] + paths, at: root).text.components(separatedBy: "\0")
        guard !entries.contains(where: { (!allowStructural && ($0.hasPrefix("120000 ") || $0.hasPrefix("160000 "))) || (!$0.isEmpty && !$0.components(separatedBy: "\t")[0].hasSuffix(" 0")) }) else {
            throw GitFailure("Resolve conflicts and handle symbolic links or submodules with Git before continuing.")
        }
        let flags = try await GitProcess.run(["ls-files", "-v", "-z", "--"] + paths, at: root).data.split(separator: 0)
        guard flags.allSatisfy({ $0.first == UInt8(ascii: "H") }) else { throw GitFailure("Clear skip-worktree and assume-unchanged flags before continuing.") }
    }

    func scratchIndex(_ data: Data?, in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("scratch-index")
        if let data { try data.write(to: url) }
        else { _ = try await GitProcess.run(["read-tree", "--empty"], at: root, indexFile: url) }
        // Recovery must not depend on an expiring shared-index file.
        _ = try await GitProcess.run(["update-index", "--no-split-index"], at: root, indexFile: url)
        return url
    }

    public func previewDiscard(paths selected: [String], scope: DiscardScope) async throws -> LocalChangePlan {
        let changes = GitParser.status(try await GitProcess.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root).data)
        guard !selected.isEmpty, selected.allSatisfy({ path in changes.contains { $0.path == path && !$0.isConflicted } }) else {
            throw GitFailure("The selection changed. Refresh and select changed files again.")
        }
        let selectedChanges = changes.filter { selected.contains($0.path) }
        let paths = Array(Set(selectedChanges.flatMap { [$0.path, scope == .allLocal ? $0.originalPath : nil].compactMap { $0 } })).sorted()
        try await requireLocalChangeSupport(paths)
        let head = try await headPosition(), index = try readLocalIndex(try await localIndexURL()), before = try localFiles(paths)
        let directory = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let temporaryIndex = try await scratchIndex(index, in: directory)
        if scope == .allLocal {
            if let hash = head.hash {
                let tracked = try await GitProcess.run(["ls-files", "-z", "--"] + paths, at: root, indexFile: temporaryIndex).text.components(separatedBy: "\0")
                let committed = try await GitProcess.run(["ls-tree", "-r", "--name-only", "-z", hash, "--"] + paths, at: root).text.components(separatedBy: "\0")
                let known = paths.filter { tracked.contains($0) || committed.contains($0) }
                if !known.isEmpty { _ = try await GitProcess.run(["restore", "--source=" + hash, "--staged", "--"] + known, at: root, indexFile: temporaryIndex) }
            } else {
                let zero = String(repeating: "0", count: head.hash?.count ?? 40)
                let input = Data(paths.map { "0 \(zero)\t\($0)\0" }.joined().utf8)
                _ = try await GitProcess.run(["update-index", "-z", "--index-info"], at: root, input: input, indexFile: temporaryIndex)
            }
        }
        let entries = try await GitProcess.run(["ls-files", "--stage", "-z", "--"] + paths, at: root, indexFile: temporaryIndex).text.components(separatedBy: "\0")
        var after: [LocalFileState] = []
        for path in paths {
            if let entry = entries.first(where: { $0.hasSuffix("\t" + path) }) {
                let header = entry.prefix { $0 != "\t" }.split(separator: " ")
                guard header.count == 3, ["100644", "100755"].contains(String(header[0])) else { throw GitFailure("The target is not a regular file: \(path)") }
                let data = try await GitProcess.run(["cat-file", "--filters", "--path=" + path, String(header[1])], at: root, indexFile: temporaryIndex).data
                after.append(LocalFileState(path: path, data: data, permissions: ((before.first { $0.path == path }?.permissions ?? 0o644) & ~0o111) | (header[0] == "100755" ? 0o111 : 0)))
            } else { after.append(LocalFileState(path: path, data: nil, permissions: nil)) }
        }
        let afterIndex = scope == .allLocal ? try readLocalIndex(temporaryIndex) : index
        guard before != after || index != afterIndex else { throw GitFailure("There are no changes in the selected scope.") }
        return LocalChangePlan(id: UUID(), title: "Discard \(scope == .unstaged ? "Unstaged" : "Local") Changes", paths: paths, preview: paths.joined(separator: "\n"), repository: root.path, head: head, beforeIndex: index, afterIndex: afterIndex, before: before, after: after)
    }

    func makeLocalScratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    func pinLocalIndex(_ data: Data?, id: UUID, side: String) async throws {
        let directory = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try await scratchIndex(data, in: directory)
        let tree = try await GitProcess.run(["write-tree"], at: root, indexFile: index).text.trimmingCharacters(in: .newlines)
        _ = try await GitProcess.run(["update-ref", "refs/gitpico/local-changes/\(id.uuidString.lowercased())/\(side)", tree], at: root)
    }

    func saveLocalBackup(_ record: LocalChangeBackup) async throws {
        let url = try await gitPicoURL("local-changes/\(record.id.uuidString).json")
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw GitFailure("Unable to save the local change backup.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: JSONEncoder().encode(record)); try handle.synchronize()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw GitFailure("Unable to install the local change backup.") }
    }

    /// The backup is durable before any worktree or real-index write.
    @discardableResult public func applyLocalChange(_ plan: LocalChangePlan) async throws -> LocalChangeBackup {
        guard plan.repository == root.path, try await headPosition() == plan.head else { throw GitFailure("The repository or HEAD changed. Reopen the preview.") }
        try validateLocalStates(plan.before, plan.after)
        guard plan.paths == plan.before.map(\.path) else { throw GitFailure("Invalid local change plan.") }
        try await requireLocalChangeSupport(plan.paths, allowStructural: true)
        let indexURL = try await localIndexURL()
        guard try readLocalIndex(indexURL) == plan.beforeIndex, try localFiles(plan.paths) == plan.before else {
            throw GitFailure("Files or staging changed after the preview. Reopen it before continuing.")
        }
        try await pinLocalIndex(plan.beforeIndex, id: plan.id, side: "before")
        try await pinLocalIndex(plan.afterIndex, id: plan.id, side: "after")
        var record = LocalChangeBackup(plan)
        try await saveLocalBackup(record)
        guard try await headPosition() == plan.head, try await currentOperation() == .none else { throw GitFailure("HEAD or the Git operation changed. No local changes were written.") }
        try commitLocalFiles(before: plan.before, after: plan.after, indexURL: indexURL, beforeIndex: plan.beforeIndex, afterIndex: plan.afterIndex)
        record.mark("applied")
        try await saveLocalBackup(record)
        return record
    }

    func commitLocalFiles(before: [LocalFileState], after: [LocalFileState], indexURL: URL, beforeIndex: Data?, afterIndex: Data?) throws {
        let lockURL = URL(fileURLWithPath: indexURL.path + ".lock")
        let descriptor = Darwin.open(lockURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw GitFailure("Git's index is locked. Wait for the other Git operation and retry.") }
        var ownsLock = true
        defer { Darwin.close(descriptor); if ownsLock { try? FileManager.default.removeItem(at: lockURL) } }
        guard try readLocalIndex(indexURL) == beforeIndex, try localFiles(before.map(\.path)) == before else {
            throw GitFailure("Files or staging changed. No local changes were written.")
        }
        var written: [Int] = []
        do {
            for index in after.indices where before[index] != after[index] {
                guard try localFiles([before[index].path]).first == before[index] else { throw GitFailure("A file changed during the operation. Recovery was retained.") }
                try writeLocalFile(after[index]); written.append(index)
            }
            if beforeIndex != afterIndex {
                if let afterIndex {
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                    try handle.write(contentsOf: afterIndex); try handle.synchronize()
                    guard Darwin.rename(lockURL.path, indexURL.path) == 0 else { throw GitFailure("Unable to install the updated index. Recovery was retained.") }
                    ownsLock = false
                } else { try FileManager.default.removeItem(at: indexURL) }
            }
        } catch {
            for index in written.reversed() {
                // Never roll back a new external edit.
                if (try? localFiles([after[index].path]).first) == after[index] { try? writeLocalFile(before[index]) }
            }
            throw error
        }
    }

    public func localChangeBackups() async throws -> [LocalChangeBackup] {
        let directory = try await gitPicoURL("local-changes")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        var records: [LocalChangeBackup] = []
        for url in urls {
            guard let value = try await self.loadRecovery(LocalChangeBackup.self, name: "local-changes/" + url.lastPathComponent), value.repository == self.root.path else { throw GitFailure("An invalid local recovery record was found.") }
            try validateLocalStates(value.before, value.after)
            records.append(value)
        }
        return records.sorted { $0.date > $1.date }
    }

    // Index stat-cache refreshes are not staging changes. Compare modes, objects,
    // stages, names and entry flags, while ignoring ctime/mtime/inode caches.
    func localIndexSignature(_ data: Data?) async throws -> [Data] {
        let directory = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = try await scratchIndex(data, in: directory)
        let output = try await GitProcess.run(["ls-files", "--stage", "--debug", "-z"], at: root, indexFile: index).data
        var cursor = output.startIndex, result: [Data] = []
        while cursor < output.endIndex {
            guard let end = output[cursor...].firstIndex(of: 0) else { throw GitFailure("Invalid index metadata.") }
            result.append(Data(output[cursor..<end])); cursor = end + 1
            var metadata = ""
            for _ in 0..<5 {
                guard let newline = output[cursor...].firstIndex(of: 10) else { throw GitFailure("Incomplete index metadata.") }
                metadata = String(decoding: output[cursor..<newline], as: UTF8.self); cursor = newline + 1
            }
            guard let range = metadata.range(of: "\tflags: ") else { throw GitFailure("Unsupported index flag metadata.") }
            result.append(Data(metadata[range.upperBound...].utf8))
        }
        return result
    }

    public func restoreLocalChanges(_ id: UUID) async throws {
        guard var record = try await loadRecovery(LocalChangeBackup.self, name: "local-changes/\(id.uuidString).json"), record.id == id, record.repository == root.path, record.state != "restored" else {
            throw GitFailure("The recovery record is missing or already restored.")
        }
        try validateLocalStates(record.before, record.after)
        guard ["prepared", "applied"].contains(record.state) else { throw GitFailure("Invalid local recovery state.") }
        try await requireLocalChangeSupport(record.paths, allowStructural: true)
        guard try await headPosition() == record.head else { throw GitFailure("HEAD changed since this backup. Return to the original branch and commit before restoring.") }
        let indexURL = try await localIndexURL(), index = try readLocalIndex(indexURL), current = try localFiles(record.paths)
        let matches = record.state == "prepared"
            ? zip(current.indices, current).allSatisfy { $0.1 == record.before[$0.0] || $0.1 == record.after[$0.0] }
            : current == record.after
        let signature = try await localIndexSignature(index)
        let expectedSignature = try await localIndexSignature(record.afterIndex)
        let beforeSignature = record.state == "prepared" ? try await localIndexSignature(record.beforeIndex) : nil
        guard matches, signature == expectedSignature || signature == beforeSignature else {
            throw GitFailure("New file or index changes would be overwritten. Commit or move them aside before restoring this backup.")
        }
        guard try await headPosition() == record.head, try await currentOperation() == .none else { throw GitFailure("HEAD or the Git operation changed during recovery.") }
        try commitLocalFiles(before: current, after: record.before, indexURL: indexURL, beforeIndex: index,
                             afterIndex: record.beforeIndex == record.afterIndex ? index : record.beforeIndex)
        record.mark("restored")
        try await saveLocalBackup(record)
    }
}

