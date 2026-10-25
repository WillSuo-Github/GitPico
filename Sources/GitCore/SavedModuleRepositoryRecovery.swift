import Foundation

public struct SavedModuleRepositoryRecoveryPlan: Sendable {
    public let backup: RelatedManagementBackup
    public let destination: URL
    let record: RelatedManagementRecord
    let workingIndex: Int?
    let gitIndex: Int?
    let embedded: Bool
}
extension GitRepository {
    public func previewSavedModuleRepositoryRecovery(_ backup: RelatedManagementBackup, to destination: URL) async throws -> SavedModuleRepositoryRecoveryPlan {
        let record = try await loadRelatedBackup(backup.id)
        guard record.summary == backup, backup.kind == "submodule" else { throw GitFailure("Select a saved submodule management backup.") }
        let destination = try await newWorktreeDestination(destination), directory = try await relatedBackupDirectory(backup.id)
        let working = record.before.directories.firstIndex { $0.path == backup.originalPath && $0.digest != nil }
        let admin = record.before.directories.firstIndex { $0.path.hasPrefix(record.common + "/") && $0.path.contains("/modules/") && $0.digest != nil }
        let embedded = try working.map { try localAttributes(directory.appendingPathComponent("directory-\($0)/.git"))?[.type] as? FileAttributeType == .typeDirectory } ?? false
        guard admin != nil || embedded else { throw GitFailure("This record has no complete saved Git storage. Use file extraction or saved-index recovery instead.") }
        for index in [working, admin].compactMap({ $0 }) {
            guard try managementDirectoryDigest(directory.appendingPathComponent("directory-\(index)")) == record.before.directories[index].digest else { throw GitFailure("Saved repository data changed or is damaged.") }
        }
        let git = embedded ? directory.appendingPathComponent("directory-\(working!)/.git") : directory.appendingPathComponent("directory-\(admin!)")
        guard try localAttributes(git.appendingPathComponent("objects"))?[.type] as? FileAttributeType == .typeDirectory, try readLocalIndex(git.appendingPathComponent("HEAD")) != nil else { throw GitFailure("This snapshot does not contain independent Git object storage.") }
        return SavedModuleRepositoryRecoveryPlan(backup: backup, destination: destination, record: record, workingIndex: working, gitIndex: admin, embedded: embedded)
    }
    @discardableResult public func recoverSavedModuleRepository(_ plan: SavedModuleRepositoryRecoveryPlan) async throws -> GitRepository {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        guard try await loadRelatedBackup(plan.backup.id) == plan.record else { throw GitFailure("The saved repository changed after preview.") }
        _ = try await previewSavedModuleRepositoryRecovery(plan.backup, to: plan.destination)
        let directory = try await relatedBackupDirectory(plan.backup.id)
        let populate: Bool
        if let working = plan.workingIndex {
            let saved = directory.appendingPathComponent("directory-\(working)")
            populate = try localAttributes(saved.appendingPathComponent(".git")) == nil && FileManager.default.contentsOfDirectory(atPath: saved.path).isEmpty
        } else { populate = true }
        if let working = plan.workingIndex { try FileManager.default.copyItem(at: directory.appendingPathComponent("directory-\(working)"), to: plan.destination) }
        else { try FileManager.default.createDirectory(at: plan.destination, withIntermediateDirectories: false) }
        let marker = plan.destination.appendingPathComponent(".git")
        if !plan.embedded {
            if try localAttributes(marker) != nil { try FileManager.default.removeItem(at: marker) }
            guard let admin = plan.gitIndex else { throw GitFailure("The saved Git directory is unavailable.") }
            try FileManager.default.copyItem(at: directory.appendingPathComponent("directory-\(admin)"), to: marker)
        }
        let recovered = GitRepository(root: plan.destination)
        try await recovered.archiveCopiedWorktrees()
        _ = try await GitProcess.run(["config", "--file", marker.appendingPathComponent("config").path, "core.worktree", plan.destination.path], at: root)
        if populate {
            let args = ["--git-dir=" + marker.path, "--work-tree=" + plan.destination.path]
            let conflicts = try await GitProcess.run(args + ["ls-files", "--unmerged", "-z"], at: plan.destination)
            guard conflicts.data.isEmpty else { throw GitFailure("The independent Git copy was preserved. Its saved index has conflicts and needs manual checkout before working files can be populated.") }
            _ = try await GitProcess.run(args + ["checkout-index", "--all"], at: plan.destination, timeout: 120)
        }
        // Child module storage moves with the saved outer .git directory. Translate owned
        // markers before scanning so no pointer is allowed to take over live old storage.
        try await recovered.translateCopiedMarkers(from: plan.backup.originalPath, oldGitDirectory: plan.record.before.pointers.first?.gitDirectory)
        let repair = try await recovered.previewPointerRepair(previousMainPath: plan.backup.originalPath, replaceBrokenMarkers: true)
        try await recovered.commitRepairFiles(before: repair.before, after: repair.after)
        return try await GitRepository.open(plan.destination)
    }
    func archiveCopiedWorktrees() throws {
        let source = root.appendingPathComponent(".git/worktrees")
        if try localAttributes(source) != nil {
            let archive = root.appendingPathComponent(".git/gitpico/recovered-worktrees/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: archive)
        }
    }
    func translateCopiedMarkers(from oldRoot: String, oldGitDirectory: String? = nil) throws {
        let common = root.appendingPathComponent(".git")
        func walk(_ folder: URL) throws {
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                if file.lastPathComponent == ".git" {
                    if try localAttributes(file)?[.type] as? FileAttributeType == .typeRegular, let original = try readGitPointer(file) {
                        var target = relocatedPath(original.path, from: oldRoot, to: root.path)
                        if let oldGitDirectory { target = relocatedPath(target, from: oldGitDirectory, to: common.path) }
                        if target.hasPrefix(root.path + "/"), !target.hasPrefix(common.appendingPathComponent("worktrees").path + "/") {
                            try Data(("gitdir: " + target + "\n").utf8).write(to: file, options: .atomic)
                        } else { try FileManager.default.removeItem(at: file) }
                    }
                    continue
                }
                if try localAttributes(file)?[.type] as? FileAttributeType == .typeDirectory { try walk(file) }
            }
        }
        try walk(root)
    }
}
