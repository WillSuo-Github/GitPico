import Foundation

public struct LegacyManagementBackup: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let date: Date
    public let source: String
}
public struct LegacyManagementRestorePlan: Sendable {
    public let backup: LegacyManagementBackup
    public let destination: URL
    public let tree: String
    let sourceData: Data
    let index: Data
    let repository: String
}
extension GitRepository {
    public func legacyManagementBackups() async throws -> [LegacyManagementBackup] {
        var result: [LegacyManagementBackup] = []
        let directory = try await gitPicoURL("submodule-backups")
        if try localAttributes(directory) != nil {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
                try checkManagementAncestors(file)
                guard let data = try readLocalIndex(file) else { continue }
                let record = try JSONDecoder().decode(SubmoduleManagementBackup.self, from: data)
                guard record.id == id, record.repository == root.path, record.index != nil else { continue }
                result.append(LegacyManagementBackup(id: "submodule:" + id.uuidString, title: record.operation + " · " + record.module.path, date: record.date, source: file.path))
            }
        }
        let management = try await managementURL("")
        if try localAttributes(management) != nil {
            for folder in try FileManager.default.contentsOfDirectory(at: management, includingPropertiesForKeys: nil) where folder.lastPathComponent.hasPrefix("worktree-") {
                guard let id = UUID(uuidString: String(folder.lastPathComponent.dropFirst(9))) else { continue }
                let index = folder.appendingPathComponent("index")
                try checkManagementAncestors(index)
                guard try readLocalIndex(index) != nil else { continue }
                let date = try FileManager.default.attributesOfItem(atPath: folder.path)[.creationDate] as? Date ?? .distantPast
                result.append(LegacyManagementBackup(id: "worktree:" + id.uuidString, title: localized("Earlier Worktree Index"), date: date, source: index.path))
            }
        }
        // A missing working directory has only its saved administrative index, just like
        // earlier backups. Offer the same isolated-tree recovery without inventing files.
        for summary in try await relatedManagementBackups() where summary.kind == "worktree" {
            let record = try await loadRelatedBackup(summary.id)
            guard record.before.directories.first(where: { $0.path == summary.originalPath })?.digest == nil,
                  let index = record.before.directories.firstIndex(where: { $0.path.hasPrefix(record.common + "/worktrees/") && $0.digest != nil }) else { continue }
            let source = try await relatedBackupDirectory(summary.id).appendingPathComponent("directory-\(index)/index")
            if try readLocalIndex(source) != nil { result.append(LegacyManagementBackup(id: "saved-index:" + summary.id.uuidString, title: localized("Saved Index · \(summary.title)"), date: summary.date, source: source.path)) }
        }
        return result.sorted { $0.date > $1.date }
    }
    public func previewLegacyManagementRestore(_ backup: LegacyManagementBackup, to destination: URL) async throws -> LegacyManagementRestorePlan {
        guard try await legacyManagementBackups().contains(backup) else { throw GitFailure("The earlier backup changed or is unavailable.") }
        let destination = try await newWorktreeDestination(destination)
        try checkManagementAncestors(URL(fileURLWithPath: backup.source))
        guard let data = try readLocalIndex(URL(fileURLWithPath: backup.source)) else { throw GitFailure("The earlier backup is missing.") }
        let index: Data
        if backup.id.hasPrefix("submodule:") {
            guard let saved = try JSONDecoder().decode(SubmoduleManagementBackup.self, from: data).index else { throw GitFailure("The earlier backup has no saved index.") }; index = saved
        } else { index = data }
        let scratch = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let temporary = try await scratchIndex(index, in: scratch)
        let tree = try await GitProcess.run(["write-tree"], at: root, indexFile: temporary).text.trimmingCharacters(in: .newlines)
        return LegacyManagementRestorePlan(backup: backup, destination: destination, tree: tree, sourceData: data, index: index, repository: root.path)
    }
    @discardableResult public func restoreLegacyManagement(_ plan: LegacyManagementRestorePlan) async throws -> ManagedWorktree {
        guard plan.repository == root.path, try await legacyManagementBackups().contains(plan.backup), try readLocalIndex(URL(fileURLWithPath: plan.backup.source)) == plan.sourceData else { throw GitFailure("The earlier backup changed after review.") }
        _ = try await newWorktreeDestination(plan.destination)
        let identity = ["GIT_AUTHOR_NAME": "GitPico Recovery", "GIT_AUTHOR_EMAIL": "recovery@gitpico.invalid", "GIT_COMMITTER_NAME": "GitPico Recovery", "GIT_COMMITTER_EMAIL": "recovery@gitpico.invalid"]
        let hash = try await GitProcess.run(["-c", "commit.gpgsign=false", "commit-tree", plan.tree, "-m", "Recovered management index snapshot"], at: root, identityEnvironment: identity).text.trimmingCharacters(in: .newlines)
        try await checkpoint(hash, id: UUID(), side: "legacy-management")
        return try await createWorktree(try await previewWorktreeCreation(destination: plan.destination, mode: .detached, revision: hash))
    }
}
