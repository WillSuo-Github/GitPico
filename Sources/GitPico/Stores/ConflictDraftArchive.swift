import CryptoKit
import Darwin
import Foundation
import GitCore

/// Orders background autosaves and the final synchronous close barrier.
final class ConflictDraftArchive: @unchecked Sendable {
    private struct Document: Codable { let root: String; let drafts: [String: ConflictDraft] }
    private let queue = DispatchQueue(label: "com.willsuo.GitPico.conflict-drafts")
    let file: URL
    private let root: String
    private var diskData: Data?
    private var loaded = false
    private var savedRevision: UInt64 = 0
    init(directory: URL, root: URL) {
        self.root = root.path
        let key = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        file = directory.appendingPathComponent(key + ".json")
    }
    func load() async throws -> [String: ConflictDraft] {
        try await Task.detached { try self.queue.sync {
            let data = try self.read()
            let document = try data.map { try JSONDecoder().decode(Document.self, from: $0) }
            guard document == nil || document?.root == self.root else { throw appFailure("Conflict drafts belong to a different repository.") }
            let values = document?.drafts ?? [:]
            try self.validate(values)
            self.diskData = data; self.loaded = true
            return values
        } }.value
    }
    func save(_ values: [String: ConflictDraft], revision: UInt64) async throws {
        try await Task.detached { try self.flush(values, revision: revision) }.value
    }
    func flush(_ values: [String: ConflictDraft], revision: UInt64) throws {
        try queue.sync {
            if !loaded, values.isEmpty { return } // Preserve an unreadable archive without trapping an unedited tab.
            guard loaded else { throw appFailure("Conflict draft storage could not be read. Export your edits before closing.") }
            guard revision >= savedRevision else { return }
            try validate(values)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Document(root: root, drafts: values))
            guard data.count <= 64 * 1024 * 1024 else { throw appFailure("Conflict drafts exceed 64 MB. Export and remove older drafts.") }
            if values.isEmpty, diskData == nil { savedRevision = revision; return }
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try checkDirectory(directory)
            let fd = Darwin.open(file.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw appFailure("Cannot lock conflict draft storage.") }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw appFailure("Another process is saving conflict drafts. Try again.") }
            defer { flock(fd, LOCK_UN) }
            guard try read() == diskData else { throw appFailure("Conflict drafts changed in another process. Keep this window open and export your edits.") }
            if data != diskData {
                let temporary = directory.appendingPathComponent("draft-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw appFailure("Cannot save conflict drafts.") }
                guard rename(temporary.path, file.path) == 0 else { throw appFailure("Cannot install the saved conflict drafts.") }
                diskData = data
            }
            savedRevision = revision
        }
    }
    private func checkDirectory(_ directory: URL) throws {
        // The app-owned directory must be real; system ancestors such as /var may be links.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path), attributes[.type] as? FileAttributeType != .typeDirectory { throw appFailure("Conflict draft storage is not a regular directory.") }
    }
    private func read() throws -> Data? {
        try checkDirectory(file.deletingLastPathComponent())
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 64 * 1024 * 1024 else { throw appFailure("Conflict draft storage is not a regular file under 64 MB.") }
        return try Data(contentsOf: file)
    }
    private func validate(_ values: [String: ConflictDraft]) throws {
        guard values.count <= 128, values.allSatisfy({ path, draft in
            !path.isEmpty && !path.hasPrefix("/") && !path.utf8.contains(0) && !path.split(separator: "/").contains("..") && draft.snapshot.path == path && draft.text.utf8.count <= 1_048_576 && draft.snapshot.canEdit
        }) else { throw appFailure("Invalid conflict drafts or too many saved edits.") }
    }
}

extension RepositoryStore {
    func loadConflictDrafts(at root: URL) async {
        conflictDraftSaveTask?.cancel()
        let archive = ConflictDraftArchive(directory: library.file.deletingLastPathComponent().appendingPathComponent("conflict-drafts"), root: root)
        conflictDraftArchive = archive; conflictDraftRevision = 0
        do {
            let drafts = try await archive.load()
            loadingConflictDrafts = true; conflictDrafts = drafts; loadingConflictDrafts = false
            conflictDraftSaveError = nil
        } catch { conflictDraftSaveError = error.localizedDescription }
    }
    func scheduleConflictDraftSave() {
        guard !loadingConflictDrafts, let archive = conflictDraftArchive else { return }
        conflictDraftRevision += 1
        let revision = conflictDraftRevision, values = conflictDrafts
        conflictDraftSaveTask?.cancel()
        conflictDraftSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await archive.save(values, revision: revision)
                guard let self, self.conflictDraftArchive === archive, self.conflictDraftRevision == revision else { return }
                self.conflictDraftSaveError = nil
            } catch is CancellationError { }
            catch {
                guard let self, self.conflictDraftArchive === archive, self.conflictDraftRevision == revision else { return }
                self.conflictDraftSaveError = error.localizedDescription
            }
        }
    }
    func flushConflictDrafts() throws {
        conflictDraftSaveTask?.cancel()
        do { try conflictDraftArchive?.flush(conflictDrafts, revision: conflictDraftRevision); conflictDraftSaveError = nil }
        catch { conflictDraftSaveError = error.localizedDescription; throw error }
    }
    func updateConflictDraft(_ snapshot: ConflictSnapshot, text: String) {
        guard snapshot.canEdit else { return }
        if text == snapshot.text { conflictDrafts.removeValue(forKey: snapshot.path) }
        else { conflictDrafts[snapshot.path] = ConflictDraft(snapshot: snapshot, text: text) }
    }
}
