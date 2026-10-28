import Foundation

public struct AutomaticStashRecord: Codable, Identifiable, Sendable {
    public enum Phase: String, Codable, Sendable { case saving, waiting, applying, needsReview }
    public let id: UUID
    public let title: String
    public let message: String
    public let originalHead: HeadPosition
    public var stashHash: String?
    public var stashSubject: String?
    public var phase: Phase
    public var restoreHead: HeadPosition?
}

extension GitRepository {
    public func automaticStashRecord() async throws -> AutomaticStashRecord? {
        guard var record = try await loadRecovery(AutomaticStashRecord.self, name: "automatic-stash.json") else { return nil }
        // Recover a crash between native stash creation and journal update.
        if record.stashHash == nil, let stash = try await stashList().first(where: { $0.subject.contains(record.message) }) {
            record.stashHash = stash.hash; record.stashSubject = stash.subject; record.phase = .waiting
            try await saveRecovery(record, name: "automatic-stash.json")
        }
        return record
    }

    public func performWithAutomaticStash(title: String, message: String = "", restoreAfter: Bool,
                                         action: @Sendable (GitRepository) async throws -> Void) async throws {
        try await requireIdleManagement()
        guard try await automaticStashRecord() == nil else { throw GitFailure("Review the pending automatic stash before starting another operation.") }
        let changes = GitParser.status(try await GitProcess.run(["status", "--porcelain=v1", "-z"], at: root).data)
        guard !changes.contains(where: \.isConflicted) else { throw GitFailure("Resolve existing conflicts before automatic stashing.") }
        guard !changes.isEmpty else { try await action(self); return }
        let id = UUID()
        let label = "Auto Stash · " + (message.isEmpty ? title : message) + " · " + id.uuidString.lowercased()
        var record = AutomaticStashRecord(id: id, title: title, message: label, originalHead: try await headPosition(), phase: .saving)
        try await saveRecovery(record, name: "automatic-stash.json")
        var options = StashSaveOptions(); options.message = label
        let stash: Stash
        do { stash = try await saveStash(options) }
        catch {
            // A stash may exist even if cleanup failed. Keep the journal for inspection.
            if try await automaticStashRecord()?.stashHash == nil, try await stashList().allSatisfy({ !$0.subject.contains(label) }) { try await clearAutomaticStash() }
            throw error
        }
        record.stashHash = stash.hash; record.stashSubject = stash.subject; record.phase = .waiting
        try await saveRecovery(record, name: "automatic-stash.json")
        // Keep an immutable recovery ref independently of the mutable stash stack.
        _ = try await backupReference(fullName: "refs/stash", hash: stash.hash, title: stash.subject)
        let status = try await GitProcess.run(["status", "--porcelain=v1", "-z"], at: root)
        guard status.data.isEmpty else { throw GitFailure("Automatic stash did not produce a clean working copy. The operation was not started; saved work is retained.") }
        if !restoreAfter { try await clearAutomaticStash() }
        do { try await action(self) }
        catch {
            let original = error
            if restoreAfter, try await currentOperation() == .none {
                do { try await finishAutomaticStashIfReady() }
                catch { throw GitFailure("\(original.localizedDescription)\n\n\(error.localizedDescription)") }
            }
            throw original
        }
        if restoreAfter { try await finishAutomaticStashIfReady() }
    }

    public func finishAutomaticStashIfReady() async throws {
        guard var record = try await automaticStashRecord(), try await currentOperation() == .none else { return }
        guard record.phase == .waiting, let hash = record.stashHash else { return }
        let changes = try await GitProcess.run(["status", "--porcelain=v1", "-z"], at: root)
        guard changes.data.isEmpty else { throw GitFailure("Automatic stash is waiting. Commit or stash current changes before restoring it.") }
        record.restoreHead = try await headPosition(); record.phase = .applying
        try await saveRecovery(record, name: "automatic-stash.json")
        do {
            _ = try await GitProcess.run(["stash", "apply", "--index", hash], at: root, timeout: 120)
        } catch {
            record.phase = .needsReview; try await saveRecovery(record, name: "automatic-stash.json")
            throw GitFailure("The operation finished, but automatic stash restoration needs review. Its saved content and staging state are retained. Resolve any conflicts, then finish recovery.\n\(error.localizedDescription)")
        }
        // Mark before removing the journal: a crash must never replay applied changes.
        record.phase = .needsReview; try await saveRecovery(record, name: "automatic-stash.json")
        try await finishAutomaticStashReview(expected: record.id)
    }

    public func finishAutomaticStashReview(expected: UUID, keepSavedStash: Bool = false) async throws {
        guard let record = try await automaticStashRecord(), record.id == expected else { throw GitFailure("The automatic stash record changed. Refresh before continuing.") }
        try await requireIdleManagement()
        let changes = GitParser.status(try await GitProcess.run(["status", "--porcelain=v1", "-z"], at: root).data)
        guard !changes.contains(where: \.isConflicted) else { throw GitFailure("Resolve and stage the conflicts before finishing automatic stash recovery.") }
        if !keepSavedStash {
            guard record.phase == .needsReview || record.phase == .applying else { throw GitFailure("Restore the saved changes first, or choose Keep Saved Stash.") }
            // A duplicate/externally renamed entry is never removed implicitly.
            let matches = try await stashList().filter { $0.hash == record.stashHash && $0.subject == record.stashSubject }
            if matches.count == 1, let stash = matches.first { try await deleteStash(stash) }
        }
        try await clearAutomaticStash()
    }

    private func clearAutomaticStash() async throws {
        let url = try await gitPicoURL("automatic-stash.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
