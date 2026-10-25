import Foundation
import Darwin

public struct RelatedManagementBackup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let title: String
    public let kind: String
    public let originalPath: String
    public let currentPath: String
    public var state: String
    public var diagnostic: String?
}
struct ManagementDirectory: Codable, Equatable, Sendable { let path: String; let digest: String? }
struct RelatedManagementSnapshot: Codable, Equatable, Sendable {
    let head: HeadPosition
    let files: [ManagementFile]
    let directories: [ManagementDirectory]
    let pointers: [RepositoryPointer]
    var additionalGuards: [ManagementFile]? = nil
}
struct RelatedManagementRecord: Codable, Equatable, Sendable {
    var summary: RelatedManagementBackup
    let repository: String
    let common: String
    let before: RelatedManagementSnapshot
    var after: RelatedManagementSnapshot?
    var worktree: ManagedWorktree? = nil
}
public struct RelatedManagementRestorePlan: Sendable {
    public let backup: RelatedManagementBackup
    public let affectedPaths: [String]
    let record: RelatedManagementRecord
    let current: RelatedManagementSnapshot
}

extension GitRepository {
    func acquireRelatedManagementLock() async throws -> Int32 {
        let file = try await managementURL("related-management.lock")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw GitFailure("Unable to open the management operation lock.") }
        let flockFunction: (Int32, Int32) -> Int32 = flock
        guard flockFunction(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw GitFailure("Another management operation is running. Wait for it before retrying.") }
        return descriptor
    }
    func releaseRelatedManagementLock(_ descriptor: Int32) { Darwin.close(descriptor) }
    func relatedBackupDirectory(_ id: UUID) async throws -> URL { try await managementURL("related/" + id.uuidString) }
    func saveRelatedBackup(_ record: RelatedManagementRecord) async throws {
        let directory = try await relatedBackupDirectory(record.summary.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("record.json")
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func loadRelatedBackup(_ id: UUID) async throws -> RelatedManagementRecord {
        let directory = try await relatedBackupDirectory(id), file = directory.appendingPathComponent("record.json")
        try checkManagementAncestors(file)
        guard let data = try readLocalIndex(file) else { throw GitFailure("The management backup is missing.") }
        let record = try JSONDecoder().decode(RelatedManagementRecord.self, from: data)
        guard record.summary.id == id, record.repository == root.path, record.common == (try await commonDirectory().path) else { throw GitFailure("This management backup belongs to another working tree.") }
        if let after = record.after {
            guard after.files.map(\.path) == record.before.files.map(\.path), after.directories.map(\.path) == record.before.directories.map(\.path) else { throw GitFailure("The backup manifest is inconsistent.") }
        }
        let paths = Set(record.before.directories.map(\.path))
        for path in paths {
            guard worktreePath(path) == path else { throw GitFailure("The backup contains a non-canonical path.") }
            guard path == record.summary.originalPath || path == record.summary.currentPath || (record.summary.kind == "worktree" && path.hasPrefix(record.common + "/worktrees/")) || (record.summary.kind == "submodule" && path.hasPrefix(record.common + "/") && path.contains("/modules/")) else { throw GitFailure("Invalid backup directory scope.") }
            try checkManagementAncestors(URL(fileURLWithPath: path))
        }
        let fixed = Set([root.appendingPathComponent(".gitmodules").path, try await localIndexURL().path, record.common + "/config"])
        for file in record.before.files + (record.after?.additionalGuards ?? []) {
            guard worktreePath(file.path) == file.path else { throw GitFailure("The backup contains a non-canonical metadata path.") }
            let url = URL(fileURLWithPath: file.path)
            let inStorage = file.path.hasPrefix(record.common + "/") && ["config", "HEAD", "index", "gitdir"].contains(url.lastPathComponent)
            let pointer = paths.contains { file.path.hasPrefix($0 + "/") } && [".git", "config", "HEAD", "index"].contains(url.lastPathComponent)
            guard fixed.contains(file.path) || inStorage || pointer else { throw GitFailure("Invalid backup metadata scope.") }
        }
        return record
    }
    public func relatedManagementBackups() async throws -> [RelatedManagementBackup] {
        let base = try await managementURL("related")
        guard try localAttributes(base) != nil else { return [] }
        var values: [RelatedManagementBackup] = []
        for entry in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: entry.lastPathComponent), FileManager.default.fileExists(atPath: entry.appendingPathComponent("record.json").path) else { continue }
            let file = try await relatedBackupDirectory(id).appendingPathComponent("record.json")
            try checkManagementAncestors(file)
            guard let data = try readLocalIndex(file) else { continue }
            let candidate = try JSONDecoder().decode(RelatedManagementRecord.self, from: data)
            if candidate.repository != root.path { continue }
            let record = try await loadRelatedBackup(id)
            values.append(record.summary)
        }
        return values.sorted { $0.date > $1.date }
    }
    func captureManagementSnapshot(files: [String], directories: [String], pointers: [RepositoryPointer], additionalGuards: [String] = []) async throws -> RelatedManagementSnapshot {
        var refreshed: [RepositoryPointer] = []
        for pointer in pointers {
            if let child = try? await GitRepository.open(URL(fileURLWithPath: pointer.workingPath)), child.root.path == pointer.workingPath {
                refreshed.append(RepositoryPointer(workingPath: pointer.workingPath, gitDirectory: pointer.gitDirectory, gitFile: pointer.gitFile, head: try await child.headPosition()))
            }
        }
        var metadata: [ManagementFile] = []
        for path in files.sorted() { metadata.append(try await managementFile(path)) }
        var snapshot = RelatedManagementSnapshot(head: try await headPosition(), files: metadata, directories: try directories.map { ManagementDirectory(path: $0, digest: try managementDirectoryDigest(URL(fileURLWithPath: $0))) }, pointers: refreshed)
        var guards: [ManagementFile] = []
        for path in additionalGuards.sorted() { guards.append(try await managementFile(path)) }
        snapshot.additionalGuards = guards.isEmpty ? nil : guards
        return snapshot
    }
    func beginRelatedBackup(title: String, kind: String, original: String, current: String, pointers: [RepositoryPointer], extraFiles: [String] = [], extraDirectories: [String] = []) async throws -> RelatedManagementRecord {
        let id = UUID()
        try await checkpoint(try await headPosition().hash, id: id, side: "management-parent")
        if kind == "submodule" { try await pinManagementIndex(try await submoduleAddIndex(), id: id, side: "management-parent-index") }
        for pointer in pointers {
            let child = GitRepository(root: URL(fileURLWithPath: pointer.workingPath))
            try await child.checkpoint(pointer.head.hash, id: id, side: "management-module")
            let index = try await child.submoduleAddIndex(); try await child.pinManagementIndex(index, id: id, side: "management-index")
        }
        let original = worktreePath(original), current = worktreePath(current)
        var files = Set(try await pointerFiles(pointers).map(\.path)); files.formUnion(extraFiles.map(worktreePath))
        let directories = Array(Set(([original, current] + extraDirectories).map(worktreePath))).sorted()
        let snapshot = try await captureManagementSnapshot(files: Array(files), directories: directories, pointers: pointers)
        let summary = RelatedManagementBackup(id: id, date: Date(), title: title, kind: kind, originalPath: original, currentPath: current, state: "prepared")
        let record = RelatedManagementRecord(summary: summary, repository: root.path, common: try await commonDirectory().path, before: snapshot)
        let directory = try await relatedBackupDirectory(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (index, folder) in snapshot.directories.enumerated() where folder.digest != nil {
            let destination = directory.appendingPathComponent("directory-\(index)")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: folder.path), to: destination)
            guard try managementDirectoryDigest(destination) == folder.digest else { throw GitFailure("A folder changed while preparing its management backup. No operation was started.") }
        }
        guard try await captureManagementSnapshot(files: Array(files), directories: directories, pointers: pointers) == snapshot else { throw GitFailure("The repository changed while saving its backup. Review again.") }
        try await saveRelatedBackup(record); return record
    }
    func finishRelatedBackup(_ initial: RelatedManagementRecord, error: Error? = nil) async throws {
        var record = initial
        var pointers = initial.before.pointers.map { pointer in
            RepositoryPointer(workingPath: relocatedPath(pointer.workingPath, from: initial.summary.originalPath, to: initial.summary.currentPath), gitDirectory: relocatedPath(pointer.gitDirectory, from: initial.summary.originalPath, to: initial.summary.currentPath), gitFile: pointer.gitFile, head: pointer.head)
        }
        if let current = try? await GitRepository.open(URL(fileURLWithPath: initial.summary.currentPath)), current.root.path == initial.summary.currentPath {
            pointers = try await current.repositoryPointers(includeRoot: initial.summary.kind == "submodule", allowedStorage: commonDirectory())
        }
        let savedPaths = Set(initial.before.files.map(\.path))
        let extraFiles = try await pointerFiles(pointers).filter { file in
            !savedPaths.contains(file.path) && !file.path.hasPrefix(initial.summary.originalPath + "/") && !file.path.hasPrefix(initial.summary.currentPath + "/")
        }
        record.after = try await captureManagementSnapshot(files: initial.before.files.map(\.path), directories: initial.before.directories.map(\.path), pointers: pointers, additionalGuards: extraFiles.map(\.path))
        record.summary.state = error == nil ? "applied" : "failed"
        record.summary.diagnostic = error?.localizedDescription
        try await saveRelatedBackup(record)
    }
    public func previewRelatedManagementRestore(_ backup: RelatedManagementBackup) async throws -> RelatedManagementRestorePlan {
        try await requireIdleManagement()
        let record = try await loadRelatedBackup(backup.id)
        guard record.summary == backup, record.summary.state != "restored" else { throw GitFailure("The backup changed or has already been restored.") }
        if let worktree = record.worktree, let branch = worktree.branch {
            guard try await references().first(where: { $0.fullName == branch })?.hash == worktree.head else { throw GitFailure("The worktree branch changed. Keep its current history before restoring this backup.") }
            let others = try await managedWorktrees().filter { $0.branch == branch && $0.path != worktree.path && $0.path != record.summary.currentPath }
            guard others.isEmpty else { throw GitFailure("The saved branch is checked out in another worktree. Close that checkout before restoring.") }
        }
        let current = try await captureManagementSnapshot(files: record.before.files.map(\.path), directories: record.before.directories.map(\.path), pointers: record.after?.pointers ?? [], additionalGuards: record.after?.additionalGuards?.map(\.path) ?? [])
        if record.summary.kind == "submodule", current.head != record.before.head { throw GitFailure("The parent's HEAD changed. Restore the original parent revision before restoring this management backup.") }
        if let after = record.after, record.summary.state != "restoring" {
            let unchanged = record.summary.kind == "worktree" ? current.files == after.files && current.directories == after.directories && current.pointers == after.pointers && current.additionalGuards == after.additionalGuards : current == after
            guard unchanged else { throw GitFailure("Files, staging, configuration or revisions changed after this operation. Keep the new changes before restoring its backup.") }
        }
        if record.summary.state == "restoring" {
            guard current.additionalGuards == record.after?.additionalGuards else { throw GitFailure("A newly initialized module changed while restore was paused.") }
            let expected = record.after ?? record.before
            for (index, file) in current.files.enumerated() {
                guard file == record.before.files[index] || file == expected.files[index] else { throw GitFailure("New Git metadata changes block resuming this restore.") }
            }
            for (index, folder) in current.directories.enumerated() {
                guard folder.digest == record.before.directories[index].digest || folder.digest == expected.directories[index].digest || folder.digest == nil else { throw GitFailure("New working files block resuming this restore.") }
            }
            for pointer in current.pointers {
                guard (record.before.pointers + expected.pointers).contains(where: { $0.workingPath == pointer.workingPath && $0.head == pointer.head }) else { throw GitFailure("A module revision changed while restore was paused.") }
            }
        }
        // Prepared records can be left by an interrupted process. Require an unchanged before state;
        // completed/failed operations carry their exact after state, and restoring is resumable below.
        if record.after == nil, record.summary.state != "restoring", current != record.before { throw GitFailure("An interrupted operation has an unknown result. Recover its saved directory manually; automatic restore cannot overwrite that state.") }
        let directory = try await relatedBackupDirectory(backup.id)
        for (index, folder) in record.before.directories.enumerated() where folder.digest != nil {
            guard try managementDirectoryDigest(directory.appendingPathComponent("directory-\(index)")) == folder.digest else { throw GitFailure("The saved directory is damaged or changed. Restore was stopped.") }
        }
        return RelatedManagementRestorePlan(backup: backup, affectedPaths: record.before.directories.map(\.path) + record.before.files.map(\.path), record: record, current: current)
    }
    public func restoreRelatedManagement(_ plan: RelatedManagementRestorePlan) async throws {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        var record = try await loadRelatedBackup(plan.backup.id)
        guard record == plan.record, try await captureManagementSnapshot(files: record.before.files.map(\.path), directories: record.before.directories.map(\.path), pointers: record.after?.pointers ?? [], additionalGuards: record.after?.additionalGuards?.map(\.path) ?? []) == plan.current else { throw GitFailure("The restore preview is stale. Review the current files again.") }
        _ = try await previewRelatedManagementRestore(plan.backup)
        try await requireIdleManagement()
        let directory = try await relatedBackupDirectory(record.summary.id)
        // Revalidate saved bytes at Apply, including resumed restores.
        for (index, folder) in record.before.directories.enumerated() where folder.digest != nil {
            guard try managementDirectoryDigest(directory.appendingPathComponent("directory-\(index)")) == folder.digest else { throw GitFailure("The saved directory changed after preview.") }
        }
        let expected = record.after ?? record.before
        record.summary.state = "restoring"; try await saveRelatedBackup(record)
        do {
            // Quarantine current folders before installing copies. Nothing is recursively deleted
            // from a live working tree, including during interruption or failed restoration.
            for (index, before) in record.before.directories.enumerated() {
                let after = expected.directories[index], target = URL(fileURLWithPath: before.path)
                guard before != after else { continue }
                let current = try managementDirectoryDigest(target), quarantine = directory.appendingPathComponent("restore-current-\(index)")
                if current == before.digest { continue }
                if current != nil {
                    guard current == after.digest, try localAttributes(quarantine) == nil else { throw GitFailure("A folder changed during recovery. Existing files and quarantine were kept.") }
                    try FileManager.default.moveItem(at: target, to: quarantine)
                }
                if before.digest != nil {
                    let staging = directory.appendingPathComponent("restore-stage-\(index)")
                    if try localAttributes(staging) != nil { try FileManager.default.removeItem(at: staging) }
                    try FileManager.default.copyItem(at: directory.appendingPathComponent("directory-\(index)"), to: staging)
                    guard try managementDirectoryDigest(staging) == before.digest else { throw GitFailure("The saved folder changed during copy.") }
                    try checkManagementAncestors(target.deletingLastPathComponent())
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: staging, to: target)
                }
            }
            // Lock every changed Git metadata file before installing any of them. Existing Git
            // locks remain owned by their creating process; no lock is removed on acquisition failure.
            var locks: [(URL, Int32)] = []
            defer { for (url, fd) in locks { Darwin.close(fd); try? FileManager.default.removeItem(at: url) } }
            for (index, before) in record.before.files.enumerated() {
                let after = expected.files[index]
                if before == after { continue }
                let current = try await managementFile(before.path)
                if current == before { continue }
                guard current == after else { throw GitFailure("Git metadata changed during recovery. Resume after keeping the new state.") }
                let lock = URL(fileURLWithPath: before.path + ".lock")
                try checkManagementAncestors(lock)
                let fd = Darwin.open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw GitFailure("Git metadata is locked. Wait for that operation, then resume this restore.") }
                locks.append((lock, fd))
            }
            for (index, before) in record.before.files.enumerated() where before != expected.files[index] {
                let current = try await managementFile(before.path)
                guard current == before || current == expected.files[index] else { throw GitFailure("Git metadata changed during restore.") }
                if current != before {
                    let url = URL(fileURLWithPath: before.path)
                    if let data = before.data { try data.write(to: url, options: .atomic) }
                    else if try localAttributes(url) != nil { try FileManager.default.removeItem(at: url) }
                }
            }
            record.summary.state = "restored"; record.summary.diagnostic = nil; try await saveRelatedBackup(record)
        } catch {
            record.summary.diagnostic = error.localizedDescription; try? await saveRelatedBackup(record)
            throw GitFailure(error.localizedDescription + "\nThe backup and quarantined data were kept. Reopen Management Backups to resume restoration.")
        }
    }
}
