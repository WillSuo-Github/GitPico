import Foundation

public struct MainRepositoryMigrationPlan: Sendable {
    public let source: URL
    public let destination: URL
    public let worktrees: [ManagedWorktree]
    public let id: UUID
    let digest: String
    let files: [ManagementFile]
    let pointers: [RepositoryPointer]
}
public struct MainRepositoryMigrationBackup: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let source: String
    public let destination: String
    public let journalDirectory: String
    public var state: String
    public var diagnostic: String?
    let originalDigest: String
    let before: [ManagementFile]
    var after: [ManagementFile]?
    var migratedDigest: String?
}
struct MainMigrationReceipt: Codable { let id: UUID; let source: String; let destination: String; let journalDirectory: String }
public struct MainMigrationRestorePlan: Sendable {
    public let backup: MainRepositoryMigrationBackup
    let currentDigest: String
    let currentFiles: [ManagementFile]
}

extension GitRepository {
    func migrationDigest(_ url: URL) throws -> String? { try managementDirectoryDigest(url, excluding: ["/.git/gitpico/main-migrations"]) }
    func mainMigrationReceipt(_ id: UUID) -> URL { root.appendingPathComponent(".git/gitpico/main-migrations/" + id.uuidString + ".json") }
    func saveMainMigration(_ record: MainRepositoryMigrationBackup) throws {
        let directory = URL(fileURLWithPath: record.journalDirectory)
        try checkManagementAncestors(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("record.json")
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func saveMainMigrationReceipt(_ record: MainRepositoryMigrationBackup) throws {
        let file = mainMigrationReceipt(record.id)
        try checkManagementAncestors(file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(MainMigrationReceipt(id: record.id, source: record.source, destination: record.destination, journalDirectory: record.journalDirectory)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func previewMainRepositoryMigration(to destination: URL) async throws -> MainRepositoryMigrationPlan {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        let trees = try await managedWorktrees(), common = try await commonDirectory()
        guard trees.first?.path == root.path, !trees[0].isBare, common.path == root.appendingPathComponent(".git").resolvingSymlinksInPath().path else { throw GitFailure("Open the main working repository before moving its Git storage.") }
        guard try await automaticStashRecord() == nil else { throw GitFailure("Finish automatic stash recovery before migrating the main repository.") }
        let destination = try await newWorktreeDestination(destination)
        var pointers: [RepositoryPointer] = [], paths = Set<String>()
        for tree in trees where !tree.isBare && tree.prunable == nil {
            let child = try await checkedWorktree(tree)
            guard try await child.currentOperation() == .none else { throw GitFailure("Finish Git operations in every available worktree before migrating shared storage.") }
            pointers += try await child.repositoryPointers(includeRoot: false, allowedStorage: common)
            if !tree.isMain {
                paths.insert(tree.path + "/.git")
                let admin = try await worktreeAdministration(tree)
                paths.formUnion([admin.path + "/gitdir", admin.path + "/commondir", admin.path + "/config.worktree", admin.path + "/index", admin.path + "/HEAD"])
            }
        }
        paths.formUnion(try await pointerFiles(pointers).map(\.path)); paths.insert(common.path + "/config")
        paths.formUnion([common.path + "/index", common.path + "/HEAD"])
        var files: [ManagementFile] = []
        for path in paths.sorted() {
            let file = try rawManagementFile(URL(fileURLWithPath: path))
            guard try localAttributes(URL(fileURLWithPath: path + ".lock")) == nil else { throw GitFailure("A Git metadata file is locked. Retry after that operation ends.") }
            files.append(file)
        }
        guard let digest = try migrationDigest(root) else { throw GitFailure("The source repository disappeared.") }
        return MainRepositoryMigrationPlan(source: root, destination: destination, worktrees: trees, id: UUID(), digest: digest, files: files, pointers: pointers)
    }
    @discardableResult public func migrateMainRepository(_ plan: MainRepositoryMigrationPlan) async throws -> GitRepository {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        guard plan.source.path == root.path, try await managedWorktrees() == plan.worktrees, try migrationDigest(root) == plan.digest else { throw GitFailure("The repository changed after the migration preview.") }
        _ = try await newWorktreeDestination(plan.destination)
        for file in plan.files {
            guard try rawManagementFile(URL(fileURLWithPath: file.path)) == file, try localAttributes(URL(fileURLWithPath: file.path + ".lock")) == nil else { throw GitFailure("Related Git metadata changed or is locked. Review migration after the other operation ends.") }
        }
        let directory = plan.destination.deletingLastPathComponent().appendingPathComponent(".gitpico-migrations/" + plan.id.uuidString)
        try checkManagementAncestors(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let saved = directory.appendingPathComponent("original-repository")
        try FileManager.default.copyItem(at: root, to: saved)
        guard try migrationDigest(saved) == plan.digest, try migrationDigest(root) == plan.digest else { throw GitFailure("The repository changed while copying its recovery data. Migration was not started.") }
        var record = MainRepositoryMigrationBackup(id: plan.id, date: Date(), source: root.path, destination: plan.destination.path, journalDirectory: directory.path, state: "prepared", originalDigest: plan.digest, before: plan.files)
        try saveMainMigration(record)
        do {
            for file in plan.files {
                guard try rawManagementFile(URL(fileURLWithPath: file.path)) == file, try localAttributes(URL(fileURLWithPath: file.path + ".lock")) == nil else { throw GitFailure("Related Git metadata changed or became locked while saving recovery data. The original repository was kept.") }
            }
            try FileManager.default.moveItem(at: root, to: plan.destination)
            record.state = "reconnecting"; try saveMainMigration(record)
            let moved = GitRepository(root: plan.destination)
            try await moved.saveMainMigrationReceipt(record)
            let repair = try await moved.previewPointerRepair(previousMainPath: plan.source.path, replaceBrokenMarkers: true)
            try await moved.commitRepairFiles(before: repair.before, after: repair.after)
            let reopened = try await GitRepository.open(plan.destination)
            for pointer in plan.pointers {
                let working = relocatedPath(pointer.workingPath, from: root.path, to: plan.destination.path)
                let child = try await GitRepository.open(URL(fileURLWithPath: working))
                guard try await child.headPosition() == pointer.head else { throw GitFailure("A module revision differs after migration. Recovery data was retained.") }
            }
            var after: [ManagementFile] = []
            for file in plan.files {
                let path = relocatedPath(file.path, from: plan.source.path, to: plan.destination.path)
                after.append(try reopened.rawManagementFile(URL(fileURLWithPath: path)))
            }
            record.after = after
            record.migratedDigest = try await reopened.migrationDigest(plan.destination)
            record.state = "applied"; try saveMainMigration(record)
            return reopened
        } catch {
            record.state = "needsRepair"; record.diagnostic = error.localizedDescription; try? saveMainMigration(record)
            throw GitFailure(error.localizedDescription + "\nRepository data is at " + (FileManager.default.fileExists(atPath: plan.destination.path) ? plan.destination.path : plan.source.path) + ". Migration recovery is saved at " + directory.path + ".")
        }
    }
    public func mainRepositoryMigrations() throws -> [MainRepositoryMigrationBackup] {
        let directory = root.appendingPathComponent(".git/gitpico/main-migrations")
        try checkManagementAncestors(directory)
        guard try localAttributes(directory) != nil else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.compactMap { file -> MainRepositoryMigrationBackup? in
            guard let data = try readLocalIndex(file) else { throw GitFailure("A migration receipt is missing.") }
            let receipt = try JSONDecoder().decode(MainMigrationReceipt.self, from: data)
            let expected = URL(fileURLWithPath: receipt.destination).deletingLastPathComponent().appendingPathComponent(".gitpico-migrations/" + receipt.id.uuidString)
            guard worktreePath(expected.path) == worktreePath(receipt.journalDirectory) else { throw GitFailure("Invalid migration recovery location.") }
            guard receipt.destination == root.path || receipt.source == root.path else { return nil }
            let recordFile = expected.appendingPathComponent("record.json"); try checkManagementAncestors(recordFile)
            guard let saved = try readLocalIndex(recordFile) else { throw GitFailure("The migration recovery data is unavailable.") }
            let record = try JSONDecoder().decode(MainRepositoryMigrationBackup.self, from: saved)
            guard record.id == receipt.id, record.source == receipt.source, record.destination == receipt.destination else { throw GitFailure("The migration receipt changed.") }; return record
        }.sorted { $0.date > $1.date }
    }
    public func loadMainMigrationJournal(at directory: URL) throws -> MainRepositoryMigrationBackup {
        try checkManagementAncestors(directory)
        guard let data = try readLocalIndex(directory.appendingPathComponent("record.json")) else { throw GitFailure("The migration journal is missing.") }
        let record = try JSONDecoder().decode(MainRepositoryMigrationBackup.self, from: data)
        let expected = URL(fileURLWithPath: record.destination).deletingLastPathComponent().appendingPathComponent(".gitpico-migrations/" + record.id.uuidString)
        guard worktreePath(expected.path) == worktreePath(directory.path), worktreePath(record.journalDirectory) == worktreePath(directory.path), record.source == root.path || record.destination == root.path else { throw GitFailure("The migration journal does not belong to this repository location.") }
        let saved = directory.appendingPathComponent("original-repository")
        guard try migrationDigest(saved) == record.originalDigest else { throw GitFailure("The original repository copy changed or is damaged.") }
        guard record.before.count == record.after?.count || record.after == nil else { throw GitFailure("The migration metadata manifest is inconsistent.") }
        var ownedRoots = [record.source]
        let admins = saved.appendingPathComponent(".git/worktrees")
        if let entries = try? FileManager.default.contentsOfDirectory(at: admins, includingPropertiesForKeys: nil) {
            for admin in entries {
                guard let data = try readLocalIndex(admin.appendingPathComponent("gitdir")), var text = String(data: data, encoding: .utf8) else { continue }
                if text.last == "\n" { text.removeLast() }; ownedRoots.append(worktreePath(URL(fileURLWithPath: text).deletingLastPathComponent().path))
            }
        }
        for file in record.before {
            guard worktreePath(file.path) == file.path, ownedRoots.contains(where: { file.path.hasPrefix($0 + "/") }), [".git", "config", "HEAD", "index", "gitdir", "commondir", "config.worktree"].contains(URL(fileURLWithPath: file.path).lastPathComponent) else { throw GitFailure("A migration metadata path is outside its recorded repositories.") }
        }
        return record
    }
    public func previewMainMigrationRestore(_ record: MainRepositoryMigrationBackup) throws -> MainMigrationRestorePlan {
        let loaded = try loadMainMigrationJournal(at: URL(fileURLWithPath: record.journalDirectory))
        guard loaded == record, ["applied", "restoring"].contains(record.state), let after = record.after, let expected = record.migratedDigest else { throw GitFailure("This migration needs pointer repair or recovery into a new folder before it can be restored in place.") }
        let original = URL(fileURLWithPath: record.source), destination = URL(fileURLWithPath: record.destination), quarantine = URL(fileURLWithPath: record.journalDirectory).appendingPathComponent("migrated-repository")
        if record.state == "applied" { guard try localAttributes(original) == nil else { throw GitFailure("The original location is occupied. Existing files were preserved.") } }
        else if try localAttributes(original) != nil { guard try migrationDigest(original) == record.originalDigest else { throw GitFailure("New files in the restored location block resuming recovery.") } }
        let live = try localAttributes(destination) != nil ? destination : quarantine
        guard try migrationDigest(live) == expected else { throw GitFailure("The migrated repository changed. Keep the new files, staging or configuration before restoring.") }
        var external: [ManagementFile] = []
        for (index, before) in record.before.enumerated() where !before.path.hasPrefix(record.source + "/") {
            let current = try rawManagementFile(URL(fileURLWithPath: before.path))
            guard current == after[index] || (record.state == "restoring" && current == before) else { throw GitFailure("A related repository changed after migration.") }
            external.append(current)
        }
        return MainMigrationRestorePlan(backup: record, currentDigest: expected, currentFiles: external)
    }
    @discardableResult public func restoreMainRepositoryMigration(_ plan: MainMigrationRestorePlan) async throws -> GitRepository {
        let fresh = try previewMainMigrationRestore(plan.backup)
        guard fresh.currentDigest == plan.currentDigest, fresh.currentFiles == plan.currentFiles else { throw GitFailure("The migration recovery preview is stale.") }
        let record = plan.backup, journal = URL(fileURLWithPath: record.journalDirectory), original = URL(fileURLWithPath: record.source), destination = URL(fileURLWithPath: record.destination)
        let live = try localAttributes(destination) != nil ? destination : try localAttributes(original) != nil ? original : journal.appendingPathComponent("migrated-repository")
        let lease = try acquireRawManagementLease(common: live.appendingPathComponent(".git")); defer { releaseRelatedManagementLock(lease) }
        _ = try previewMainMigrationRestore(record)
        try checkManagementAncestors(original.deletingLastPathComponent())
        guard try localAttributes(original.deletingLastPathComponent())?[.type] as? FileAttributeType == .typeDirectory else { throw GitFailure("The original parent folder is missing.") }
        var updated = record; updated.state = "restoring"; try saveMainMigration(updated)
        do {
            let quarantine = journal.appendingPathComponent("migrated-repository")
            if try localAttributes(destination) != nil {
                guard try localAttributes(quarantine) == nil else { throw GitFailure("A migration quarantine already exists. No repository was overwritten.") }
                try FileManager.default.moveItem(at: destination, to: quarantine)
            }
            if try localAttributes(original) == nil {
                let staging = journal.appendingPathComponent("restore-original")
                if try localAttributes(staging) != nil { try FileManager.default.removeItem(at: staging) }
                try FileManager.default.copyItem(at: journal.appendingPathComponent("original-repository"), to: staging)
                guard try migrationDigest(staging) == record.originalDigest else { throw GitFailure("Recovery data changed during copying.") }
                try FileManager.default.moveItem(at: staging, to: original)
            }
            let restored = GitRepository(root: original)
            try await restored.saveMainMigrationReceipt(updated)
            let externalBefore = record.before.filter { !$0.path.hasPrefix(record.source + "/") }
            try await restored.commitRepairFiles(before: plan.currentFiles, after: externalBefore, allowPartial: true)
            updated.state = "restored"; updated.diagnostic = nil; try saveMainMigration(updated)
            return try await GitRepository.open(original)
        } catch {
            updated.diagnostic = error.localizedDescription; try? saveMainMigration(updated)
            throw GitFailure(error.localizedDescription + "\nBoth repository copies were kept in " + journal.path + ". Reopen the migration history at its current location to resume.")
        }
    }
}
