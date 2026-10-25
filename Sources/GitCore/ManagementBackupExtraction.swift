import Foundation

public struct ManagementBackupExtractionPlan: Sendable {
    public let backup: RelatedManagementBackup
    public let destination: URL
    public let originalPath: String
    let record: RelatedManagementRecord
    let directoryIndex: Int
}
extension GitRepository {
    public func previewManagementBackupExtraction(_ backup: RelatedManagementBackup, to destination: URL) async throws -> ManagementBackupExtractionPlan {
        let record = try await loadRelatedBackup(backup.id)
        guard record.summary == backup, let index = record.before.directories.firstIndex(where: { $0.path == record.summary.originalPath && $0.digest != nil }) else { throw GitFailure("This backup does not contain a saved working directory.") }
        let destination = try await newWorktreeDestination(destination)
        let source = try await relatedBackupDirectory(backup.id).appendingPathComponent("directory-\(index)")
        guard try managementDirectoryDigest(source) == record.before.directories[index].digest else { throw GitFailure("The saved files changed. Extraction was stopped.") }
        return ManagementBackupExtractionPlan(backup: backup, destination: destination, originalPath: record.summary.originalPath, record: record, directoryIndex: index)
    }
    public func extractManagementBackupFiles(_ plan: ManagementBackupExtractionPlan) async throws {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        guard try await loadRelatedBackup(plan.backup.id) == plan.record else { throw GitFailure("The backup changed after preview.") }
        _ = try await newWorktreeDestination(plan.destination)
        let directory = try await relatedBackupDirectory(plan.backup.id), source = directory.appendingPathComponent("directory-\(plan.directoryIndex)")
        guard try managementDirectoryDigest(source) == plan.record.before.directories[plan.directoryIndex].digest else { throw GitFailure("The saved directory changed after preview.") }
        let staging = directory.appendingPathComponent("extract-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        guard try managementDirectoryDigest(staging) == plan.record.before.directories[plan.directoryIndex].digest else { throw GitFailure("The saved files changed while copying.") }
        func removeGitMarkers(_ folder: URL) throws {
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                if file.lastPathComponent == ".git" { try FileManager.default.removeItem(at: file) }
                else if try localAttributes(file)?[.type] as? FileAttributeType == .typeDirectory { try removeGitMarkers(file) }
            }
        }
        try removeGitMarkers(staging)
        try FileManager.default.moveItem(at: staging, to: plan.destination)
    }
}
