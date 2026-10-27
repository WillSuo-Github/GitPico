import Foundation
import GitCore
import Observation

extension RepositoryStore {
    var aiCommitUnavailableReason: String? {
        if repository == nil { return "Open a repository before generating a commit message." }
        if isBusy { return "Wait for the current repository operation to finish before generating a message." }
        if changes.contains(where: \.isConflicted) { return "Resolve and stage conflicted files before generating a commit message." }
        if staged.isEmpty { return "Stage at least one change in Working Copy before generating a commit message. You can configure your AI tool now." }
        return nil
    }
}

@MainActor @Observable final class AICommitSession {
    private(set) var isGenerating = false
    private(set) var isApplying = false
    private(set) var hasMessage = false
    var summary = ""
    var body = ""
    var error: String?
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var fingerprint: String?
    @ObservationIgnored private var repositoryToken: UUID?
    @ObservationIgnored private var originalSummary = ""
    @ObservationIgnored private var originalBody = ""
    @ObservationIgnored private var amend = false
    @ObservationIgnored private let generator: any AICommitGenerating
    init(generator: any AICommitGenerating = AICommitCLI()) { self.generator = generator }

    func generate(in store: RepositoryStore, settings: AICommitSettings, executable: URL) {
        guard !isGenerating, !isApplying else { return }
        if let reason = store.aiCommitUnavailableReason { error = reason; return }
        guard let repository = store.repository else { return }
        cancel()
        let generation = generation, token = store.repositoryToken
        let subject = store.commitSubject, description = store.commitBody, amend = store.amend
        isGenerating = true; hasMessage = false; error = nil
        task = Task {
            defer { if self.generation == generation { isGenerating = false } }
            do {
                let context = try await repository.aiCommitContext()
                try Task.checkCancellation()
                guard store.repositoryToken == token else { throw GitFailure("The repository changed. Reopen AI Commit Message.") }
                let message = try await generator.generate(provider: settings.provider, executable: executable, prompt: context.prompt(language: settings.language.rawValue))
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                guard store.repositoryToken == token, store.amend == amend, !store.isBusy,
                      try await repository.aiCommitFingerprint() == context.fingerprint else {
                    throw GitFailure("The staged changes or commit mode changed. Generate a new message.")
                }
                guard self.generation == generation, store.repositoryToken == token else { return }
                summary = message.summary; body = message.body; fingerprint = context.fingerprint; repositoryToken = token
                originalSummary = subject; originalBody = description; self.amend = amend; hasMessage = true
            } catch is CancellationError { }
            catch { if self.generation == generation { self.error = error.localizedDescription } }
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isGenerating = false
    }
    func apply(to store: RepositoryStore) async throws {
        guard hasMessage, !isGenerating, !isApplying, !store.isBusy, let repository = store.repository,
              store.repositoryToken == repositoryToken, store.amend == amend else { throw GitFailure("The repository or commit mode changed. Generate a new message.") }
        isApplying = true; defer { isApplying = false }
        let generation = generation
        let message = AICommitMessage(summary: summary.trimmingCharacters(in: .whitespacesAndNewlines), body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        try message.validate()
        let current = try await repository.aiCommitFingerprint()
        guard self.generation == generation, store.repositoryToken == repositoryToken, store.amend == amend, !store.isBusy, current == fingerprint else {
            throw GitFailure("The staged changes moved. Generate a new message before using it.")
        }
        guard store.commitSubject == originalSummary, store.commitBody == originalBody else { throw GitFailure("Your commit draft changed during generation. Copy the suggestion or generate again to keep your edits.") }
        store.commitSubject = message.summary; store.commitBody = message.body
    }
}
