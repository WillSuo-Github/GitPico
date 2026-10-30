import Foundation
import GitCore
import Observation

extension RepositoryStore {
    var aiCommitUnavailableReason: String? {
        aiCommitUnavailableReason(scope: .staged)
    }
    func aiCommitUnavailableReason(scope: AICommitScope) -> String? {
        if repository == nil { return String(localized: "Open a repository before generating a commit message.") }
        if isBusy { return String(localized: "Wait for the current repository operation to finish before generating a message.") }
        if changes.contains(where: \.isConflicted) { return String(localized: "Resolve and stage conflicted files before generating a commit message.") }
        if scope == .staged && staged.isEmpty { return String(localized: "Stage at least one change before generating a commit message.") }
        if scope == .allChanges && changes.isEmpty { return String(localized: "Make at least one change before generating a commit message.") }
        return nil
    }
}

/// Generates a commit message from the selected changes and writes it straight into the commit editor.
@MainActor @Observable final class AICommitSession {
    private(set) var isGenerating = false
    var error: String?
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let generator: any AICommitGenerating
    init(generator: any AICommitGenerating = AICommitCLI()) { self.generator = generator }

    func generate(in store: RepositoryStore, settings: AICommitSettings, provider: AICommitProvider, executable: URL, scope: AICommitScope = .staged) {
        guard !isGenerating else { return }
        if let reason = store.aiCommitUnavailableReason(scope: scope) { error = reason; return }
        guard let repository = store.repository else { return }
        cancel()
        let generation = generation, token = store.repositoryToken
        let subject = store.commitSubject, description = store.commitBody, amend = store.amend
        isGenerating = true; error = nil
        task = Task {
            defer { if self.generation == generation { isGenerating = false } }
            do {
                let context = try await repository.aiCommitContext(scope: scope)
                try Task.checkCancellation()
                guard store.repositoryToken == token else { throw appFailure("The repository changed. Generate a new message.") }
                let prompt = context.prompt(language: settings.language.rawValue, instructions: settings.effectiveInstructions)
                let message = try await generator.generate(provider: provider, executable: executable, prompt: prompt)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                guard store.repositoryToken == token, store.amend == amend, !store.isBusy,
                      try await repository.aiCommitFingerprint(scope: scope) == context.fingerprint else {
                    throw appFailure("The selected changes or commit mode changed. Generate a new message.")
                }
                guard self.generation == generation, store.repositoryToken == token else { return }
                guard store.commitSubject == subject, store.commitBody == description else {
                    throw appFailure("You edited the commit message while AI was writing, so it was kept. Click AI again to replace it.")
                }
                store.commitSubject = message.summary; store.commitBody = message.body
            } catch is CancellationError { }
            catch { if self.generation == generation { self.error = error.localizedDescription } }
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isGenerating = false
    }
}
