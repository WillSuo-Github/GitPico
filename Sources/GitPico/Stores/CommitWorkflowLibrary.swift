import Foundation
import GitCore
import Observation

struct CommitTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var text: String
}
struct CommitIdentityProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var name: String
    var email: String
}
@MainActor @Observable final class CommitWorkflowLibrary {
    static let shared = CommitWorkflowLibrary(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GitPico/commit-workflows.json"))
    private struct Archive: Codable { var version = 1; var templates: [CommitTemplate] = []; var identities: [CommitIdentityProfile] = [] }
    private var archive = Archive()
    var templates: [CommitTemplate] { archive.templates }
    var identities: [CommitIdentityProfile] { archive.identities }
    private(set) var error: String?
    private let file: URL
    private var diskData: Data?
    private var loaded = false
    init(file: URL) {
        self.file = file
        do {
            try checkStorage()
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard data.count <= 2 * 1024 * 1024 else { throw GitFailure("Commit workflow storage exceeds 2 MB.") }
                let value = try JSONDecoder().decode(Archive.self, from: data)
                try validate(value); archive = value; diskData = data
            }
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
    func save(template: CommitTemplate) throws {
        var value = archive
        if let index = value.templates.firstIndex(where: { $0.id == template.id }) { value.templates[index] = template }
        else { value.templates.append(template) }
        try persist(value)
    }
    func save(identity: CommitIdentityProfile) throws {
        var value = archive
        if let index = value.identities.firstIndex(where: { $0.id == identity.id }) { value.identities[index] = identity }
        else { value.identities.append(identity) }
        try persist(value)
    }
    func remove(template: UUID) throws { var value = archive; value.templates.removeAll { $0.id == template }; try persist(value) }
    func remove(identity: UUID) throws { var value = archive; value.identities.removeAll { $0.id == identity }; try persist(value) }
    private func validate(_ value: Archive) throws {
        guard value.version == 1, value.templates.count <= 100, value.identities.count <= 100,
              Set(value.templates.map(\.id)).count == value.templates.count, Set(value.identities.map(\.id)).count == value.identities.count,
              value.templates.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 100 && $0.text.utf8.count <= 256 * 1024 && !$0.text.utf8.contains(0) }),
              value.identities.allSatisfy({ [$0.label, $0.name, $0.email].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 200 && !$0.contains(where: { $0.isNewline || $0 == "\0" }) } }) else { throw GitFailure("Invalid commit workflow library. Use named templates up to 256 KB and single-line identities; at most 100 of each.") }
    }
    private func checkStorage() throws {
        for current in [file, file.deletingLastPathComponent()] {
            if let type = try? FileManager.default.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType {
                guard type != .typeSymbolicLink, current != file || type == .typeRegular else { throw GitFailure("Commit workflow storage must not contain symbolic links or nonregular files.") }
            }
        }
    }
    private func persist(_ value: Archive) throws {
        guard loaded else { throw GitFailure("Commit workflow storage could not be loaded. Preserve it and reopen after repairing it.") }
        try validate(value); try checkStorage()
        let current = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        guard current == diskData else { throw GitFailure("Commit workflows changed outside this window. Reopen the app before saving.") }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 2 * 1024 * 1024 else { throw GitFailure("Commit workflow storage exceeds 2 MB.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        archive = value; diskData = data; error = nil
    }
}
