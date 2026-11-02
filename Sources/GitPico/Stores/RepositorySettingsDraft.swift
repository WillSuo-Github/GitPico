import Foundation
import GitCore
import Observation

struct RepositoryGeneralSettings: Equatable, Sendable {
    var name: String
    var email: String
    var description: String
    var signCommits: Bool
    var signingKey: String
    init(_ value: RepositoryConfiguration) {
        name = value.identity.name; email = value.identity.email; description = value.description
        signCommits = value.signCommits; signingKey = value.signingKey
    }
    mutating func useIdentity(_ profile: CommitIdentityProfile) { name = profile.name; email = profile.email }
}

@MainActor @Observable final class IgnoreSettingsDraft {
    let kind: GitRepository.IgnoreFile
    var text = ""
    var original: String?
    var path = ""
    var error: String?
    var loading = false
    var isDirty: Bool { original.map { text != $0 } ?? false }
    init(_ kind: GitRepository.IgnoreFile) { self.kind = kind }
    func load(from repository: GitRepository) async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let value = try await repository.readIgnoreFile(kind)
            path = try await repository.ignoreFileURL(kind).path
            text = value; original = value; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor @Observable final class RepositorySettingsDraft {
    static let gitDefaultDescription = "Unnamed repository; edit this file 'description' to name the repository."
    var general: RepositoryGeneralSettings?
    private var original: RepositoryGeneralSettings?
    let ignores = IgnoreSettingsDraft(.ignores)
    let excludes = IgnoreSettingsDraft(.excludes)
    var saving = false
    var failure: String?
    var generalIsDirty: Bool { general != original }
    var hasChanges: Bool { generalIsDirty || ignores.isDirty || excludes.isDirty }
    var canSave: Bool {
        guard hasChanges, !saving else { return false }
        return !generalIsDirty || (general?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && general?.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
    func load(_ value: RepositoryConfiguration) { general = RepositoryGeneralSettings(value); original = general }
    func save(in store: RepositoryStore) async -> Bool {
        guard canSave, !store.isBusy, store.repository != nil else { return false }
        let submitted = generalIsDirty ? general : nil
        let files = [ignores, excludes].filter(\.isDirty).compactMap { draft -> (IgnoreSettingsDraft, String, String)? in
            guard let original = draft.original else { return nil }; return (draft, draft.text, original)
        }
        saving = true; failure = nil
        defer { saving = false }
        store.perform("Saving repository settings…") { repository in
            do {
                if let value = submitted {
                    try await repository.saveConfiguration(name: value.name, email: value.email, description: value.description, signCommits: value.signCommits, signingKey: value.signingKey)
                    await self.accept(value)
                }
                for (draft, text, original) in files {
                    try await repository.writeIgnoreFile(draft.kind, text: text, expected: original)
                    await self.accept(draft, text: text)
                }
            } catch { await self.failed(error.localizedDescription); throw error }
        }
        await store.operationTask?.value
        return failure == nil && !hasChanges
    }
    private func accept(_ value: RepositoryGeneralSettings) { original = value }
    private func accept(_ draft: IgnoreSettingsDraft, text: String) { draft.original = text }
    private func failed(_ message: String) { failure = message }
}
