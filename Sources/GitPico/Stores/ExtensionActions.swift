import Foundation
import GitCore

enum LFSAction { case renormalize([String]), change(LFSChange), transfer(LFSTransfer), restore(LFSChangeRecord) }
struct LFSRequest: Identifiable { let id = UUID(); let token: UUID; let action: LFSAction }
enum FlowAction { case configure, start(GitFlowKind), finish(String), resume(GitFlowRecord), stop(GitFlowRecord) }
struct FlowRequest: Identifiable { let id = UUID(); let token: UUID; let action: FlowAction }

extension RepositoryStore {
    func showLFS() { settingsTab = "Git LFS"; navigate(.repositorySettings) }
    func showGitFlow() { settingsTab = "Git Flow"; navigate(.repositorySettings) }
    func loadWorkflowState() async {
        guard let repository else { return }
        let token = repositoryToken, epoch = metadataEpoch
        do {
            let config = try await repository.gitFlowConfiguration(), active = try await repository.activeGitFlow(), history = try await repository.gitFlowHistory()
            guard token == repositoryToken && epoch == metadataEpoch else { return }
            flowConfiguration = config; activeFlow = active; flowHistory = history; workflowError = nil; metadataDirty.remove(.workflow)
        } catch { if token == repositoryToken && epoch == metadataEpoch { metadataDirty.insert(.workflow); workflowError = error.localizedDescription } }
    }
    func loadLFS() async {
        guard let repository else { return }
        let token = repositoryToken, epoch = metadataEpoch
        do {
            let state = try await repository.lfsState(), changes = try await repository.lfsChangeHistory(), transfers = try await repository.lfsTransferHistory()
            guard token == repositoryToken && epoch == metadataEpoch else { return }
            lfsState = state; lfsChanges = changes; lfsTransfers = transfers; lfsError = nil
        } catch { if token == repositoryToken && epoch == metadataEpoch { lfsError = error.localizedDescription } }
    }
    func manageLFS(_ action: LFSAction) {
        guard repository != nil, !isBusy else { return }
        lfsRequest = LFSRequest(token: repositoryToken, action: action)
    }
    func manageFlow(_ action: FlowAction) {
        guard repository != nil, !isBusy else { return }
        withFreshMetadata([.workflow]) { self.flowRequest = FlowRequest(token: self.repositoryToken, action: action) }
    }
    func applyLFS(_ plan: LFSChangePlan, request: LFSRequest) {
        runExtension(token: request.token, activity: "Updating LFS settings…") { try await $0.applyLFSChange(plan) }
    }
    func stageLFS(_ plan: LFSStagingPlan, request: LFSRequest) {
        runExtension(token: request.token, activity: "Staging LFS conversion…") { try await $0.applyLFSStaging(plan) }
    }
    func restoreLFS(_ record: LFSChangeRecord, request: LFSRequest) {
        runExtension(token: request.token, activity: "Restoring saved LFS settings…") { try await $0.restoreLFSChange(record) }
    }
    func transferLFS(_ plan: LFSTransferPlan, request: LFSRequest) {
        let token = request.token
        runExtension(token: token, activity: plan.operation.rawValue + "…") { [weak self] repository in
            _ = try await repository.runLFSTransfer(plan) { [weak self] message in
                await self?.setLFSProgress(message, token: token)
            }
        }
    }
    private func setLFSProgress(_ message: String, token: UUID) { if token == repositoryToken { lfsProgress = message } }
    func applyFlow(_ plan: GitFlowPlan, request: FlowRequest) {
        runExtension(token: request.token, activity: "Running Git Flow…") { _ = try await $0.applyGitFlow(plan) }
    }
    func continueFlow(_ record: GitFlowRecord, stop: Bool, request: FlowRequest) {
        runExtension(token: request.token, activity: stop ? "Stopping Git Flow…" : "Continuing Git Flow…") { repository in
            if stop { try await repository.stopGitFlow(record) } else { _ = try await repository.resumeGitFlow(record) }
        }
    }
    private func runExtension(token: UUID, activity: String, operation: @escaping @Sendable (GitRepository) async throws -> Void) {
        guard !isBusy, let repository, token == repositoryToken else { error = "The repository changed. Reopen this extension preview."; return }
        isBusy = true; self.activity = activity
        Task {
            do { try await operation(repository) }
            catch { self.error = error.localizedDescription }
            do { try await reload() } catch { self.error = error.localizedDescription }
            await loadWorkflowState(); await loadLFS()
            isBusy = false; self.activity = ""
        }
    }
}
