import Foundation
import GitCore

struct RepositoryCommitDraft: Codable, Equatable {
    var subject: String
    var body: String
    var updated = Date()
}

@MainActor final class RepositoryDraftStore {
    let file: URL
    private(set) var values: [String: RepositoryCommitDraft] = [:]
    private var loaded = false
    private var diskData: Data?
    private(set) var error: String?

    init(file: URL) {
        self.file = file
        do {
            try checkStorage()
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count <= 4 * 1024 * 1024 else { throw appFailure("Commit draft storage is too large.") }
                values = try JSONDecoder().decode([String: RepositoryCommitDraft].self, from: data)
                guard values.count <= 500, values.keys.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) else { throw appFailure("Invalid commit draft storage.") }
                diskData = data
            }
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
    func update(path: String, subject: String, body: String) {
        if subject.isEmpty && body.isEmpty { values.removeValue(forKey: path) }
        else { values[path] = RepositoryCommitDraft(subject: subject, body: body) }
        if values.count > 500, let oldest = values.min(by: { $0.value.updated < $1.value.updated })?.key { values.removeValue(forKey: oldest) }
    }
    func flush() throws {
        if !loaded {
            try checkStorage()
            var saved: [String: RepositoryCommitDraft] = [:]
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count <= 4 * 1024 * 1024 else { throw appFailure("Commit draft storage is too large.") }
                saved = try JSONDecoder().decode([String: RepositoryCommitDraft].self, from: data)
                guard saved.count <= 500, saved.keys.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) else { throw appFailure("Invalid commit draft storage.") }
            }
            values = saved.merging(values) { _, current in current }; loaded = true
        }
        try checkStorage()
        guard values.count <= 500 else { throw appFailure("Too many commit drafts to save. Keep this tab open and review draft storage.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(values)
        guard data.count <= 4 * 1024 * 1024 else { throw appFailure("Commit drafts exceed the storage limit. Shorten the draft before closing this tab.") }
        guard data != diskData else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic); diskData = data; error = nil
    }
    private func checkStorage() throws {
        for url in [file, file.deletingLastPathComponent()] {
            if let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType {
                guard type != .typeSymbolicLink else { throw appFailure("Commit draft storage contains a symbolic link.") }
                if url == file { guard type == .typeRegular else { throw appFailure("Commit draft storage is not a regular file.") } }
            }
        }
    }
}
