import Foundation
import GitCore
import Observation

enum AICommitLanguage: String, CaseIterable, Codable, Identifiable {
    case english = "English", chinese = "Simplified Chinese"
    var id: String { rawValue }
}
struct AICommitSettings: Codable, Equatable {
    /// nil follows the first CLI detected on this Mac.
    var provider: AICommitProvider?
    var language: AICommitLanguage = .english
    var executables: [String: String] = [:]
    /// nil uses the built-in Conventional Commits guidelines.
    var instructions: String?
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decodeIfPresent(AICommitProvider.self, forKey: .provider)
        language = try values.decodeIfPresent(AICommitLanguage.self, forKey: .language) ?? .english
        executables = try values.decodeIfPresent([String: String].self, forKey: .executables) ?? [:]
        instructions = try values.decodeIfPresent(String.self, forKey: .instructions)
    }
    func executableOverride(for provider: AICommitProvider) -> String { executables[provider.rawValue] ?? "" }
    func executable(for provider: AICommitProvider) -> URL? { provider.executable(override: executableOverride(for: provider)) }
    func resolvedProvider(detect: (AICommitProvider) -> URL? = { _ in nil }) -> AICommitProvider {
        provider ?? AICommitProvider.allCases.first { detect($0) != nil } ?? .codex
    }
    var resolvedProvider: AICommitProvider { resolvedProvider(detect: executable(for:)) }
    var effectiveInstructions: String {
        let text = instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? AICommitContext.defaultInstructions : text
    }
}
@MainActor @Observable final class AICommitPreferences {
    static let shared = AICommitPreferences()
    private(set) var value = AICommitSettings()
    private(set) var error: String?
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var original: Data?
    @ObservationIgnored private var valid = false
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GitPico/ai-commit.json")
        do {
            original = try read()
            if let original { value = try JSONDecoder().decode(AICommitSettings.self, from: original) }
            valid = true
        } catch { self.error = error.localizedDescription }
    }
    private func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 64 * 1024 else { throw appFailure("AI commit settings must be a regular file under 64 KB.") }
        return try Data(contentsOf: file)
    }
    func save(_ value: AICommitSettings) throws {
        guard valid else { throw appFailure("AI commit settings could not be loaded. Preserve the existing file and repair it before saving.") }
        guard try read() == original else { throw appFailure("AI commit settings changed outside this window. Reopen the app before saving.") }
        guard value.executables.values.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }) else { throw appFailure("The CLI path is too long or invalid.") }
        guard (value.instructions?.utf8.count ?? 0) <= 16 * 1024, value.instructions?.contains("\0") != true else { throw appFailure("The commit message prompt must be under 16 KB.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(value)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        self.value = value; original = data; error = nil
    }
}
