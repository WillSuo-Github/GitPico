import Foundation

public struct MainRepositoryRecoveryPlan: Sendable {
    public let backup: MainRepositoryMigrationBackup
    public let destination: URL
}
extension GitRepository {
    func newMainRecoveryDestination(_ destination: URL, record: MainRepositoryMigrationBackup) throws -> URL {
        guard destination.isFileURL, destination.path.hasPrefix("/"), !destination.path.utf8.contains(0) else { throw GitFailure("Choose a new absolute recovery folder.") }
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath(), target = parent.appendingPathComponent(destination.lastPathComponent)
        try checkManagementAncestors(target)
        guard try localAttributes(target) == nil, try localAttributes(parent)?[.type] as? FileAttributeType == .typeDirectory else { throw GitFailure("The recovery destination must be new, with an existing parent folder.") }
        for path in [record.source, record.destination, record.journalDirectory] {
            guard target.path != path, !target.path.hasPrefix(path + "/"), !path.hasPrefix(target.path + "/") else { throw GitFailure("Use a separate recovery folder outside the original, migrated and backup directories.") }
        }
        return target
    }
    public func previewSavedMainRepositoryRecovery(_ record: MainRepositoryMigrationBackup, to destination: URL) throws -> MainRepositoryRecoveryPlan {
        guard try loadMainMigrationJournal(at: URL(fileURLWithPath: record.journalDirectory)) == record else { throw GitFailure("The migration record changed.") }
        return MainRepositoryRecoveryPlan(backup: record, destination: try newMainRecoveryDestination(destination, record: record))
    }
    @discardableResult public func recoverSavedMainRepository(_ plan: MainRepositoryRecoveryPlan) async throws -> GitRepository {
        _ = try previewSavedMainRepositoryRecovery(plan.backup, to: plan.destination)
        let saved = URL(fileURLWithPath: plan.backup.journalDirectory).appendingPathComponent("original-repository")
        try FileManager.default.copyItem(at: saved, to: plan.destination)
        guard try migrationDigest(plan.destination) == plan.backup.originalDigest else { throw GitFailure("The recovery copy differs from the saved repository. Both copies were kept.") }
        let common = plan.destination.appendingPathComponent(".git")
        // Only edit the newly created copy. Shared external worktree registrations stay
        // with the live repository; their original data remains in the migration backup.
        try await GitRepository(root: plan.destination).archiveCopiedWorktrees()
        func reconnectCopiedMarkers(_ directory: URL) throws {
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if child.lastPathComponent == ".git" {
                    if try localAttributes(child)?[.type] as? FileAttributeType == .typeRegular {
                        if let original = try readGitPointer(child) {
                            let target = relocatedPath(original.path, from: plan.backup.source, to: plan.destination.path)
                            if target.hasPrefix(plan.destination.path + "/"), !target.hasPrefix(common.appendingPathComponent("worktrees").path + "/") {
                                try Data(("gitdir: " + target + "\n").utf8).write(to: child, options: .atomic)
                            } else { try FileManager.default.removeItem(at: child) }
                        }
                    }
                    continue
                }
                if try localAttributes(child)?[.type] as? FileAttributeType == .typeDirectory { try reconnectCopiedMarkers(child) }
            }
        }
        try reconnectCopiedMarkers(plan.destination)
        let recovered = GitRepository(root: plan.destination)
        let repair = try await recovered.previewPointerRepair(previousMainPath: plan.backup.source, replaceBrokenMarkers: true)
        try await recovered.commitRepairFiles(before: repair.before, after: repair.after)
        return try await GitRepository.open(plan.destination)
    }
}
