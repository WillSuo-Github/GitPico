import Foundation
import GitCore

enum RelatedAdministrationAction {
    case worktrees([ManagedWorktree]), submodules([ManagedSubmodule]), backups, resume(RelatedBatchReport)
}
struct RelatedAdministrationRequest: Identifiable {
    let id = UUID()
    let repositoryToken: UUID
    let action: RelatedAdministrationAction
    var initialWorktreeOperation: WorktreeBatchOperation? = nil
}
extension RepositoryStore {
    func relatedAdministration(_ action: RelatedAdministrationAction, initialWorktreeOperation: WorktreeBatchOperation? = nil) {
        guard !isBusy, repository != nil else { return }
        relatedBatchProgress = nil
        relatedAdministrationRequest = RelatedAdministrationRequest(repositoryToken: repositoryToken, action: action, initialWorktreeOperation: initialWorktreeOperation)
    }
    func runRelatedBatch(_ plan: RelatedBatchPlan, request: RelatedAdministrationRequest) {
        guard !isBusy, let repository, request.repositoryToken == repositoryToken else { error = String(localized: "The repository changed. Reopen this batch preview."); return }
        isBusy = true; activity = plan.report.title + "…"; relatedBatchProgress = plan.report
        relatedBatchTask = Task {
            do {
                relatedBatchProgress = try await repository.applyRelatedBatch(plan) { [self] report in
                    await MainActor.run { self.relatedBatchProgress = report }
                }
                try await reload()
            } catch { self.error = error.localizedDescription; try? await reload() }
            isBusy = false; activity = ""; relatedBatchTask = nil
        }
    }
    func recoverSavedModule(_ plan: SavedModuleRepositoryRecoveryPlan, request: RelatedAdministrationRequest) {
        guard !isBusy, request.repositoryToken == repositoryToken, let repository else { error = String(localized: "The repository changed. Reopen the saved repository preview."); return }
        isBusy = true; activity = String(localized: "Recovering saved submodule repository…")
        Task {
            do { let recovered = try await repository.recoverSavedModuleRepository(plan); let url = await recovered.root; isBusy = false; await open(url) }
            catch { self.error = error.localizedDescription; isBusy = false }
            activity = ""
        }
    }
    func extractManagementFiles(_ plan: ManagementBackupExtractionPlan, request: RelatedAdministrationRequest) {
        guard request.repositoryToken == repositoryToken else { error = String(localized: "The repository changed. Reopen this preview."); return }
        perform("Extracting saved management files…") { try await $0.extractManagementBackupFiles(plan) }
    }
    func restoreEarlierManagement(_ plan: LegacyManagementRestorePlan, request: RelatedAdministrationRequest) {
        guard request.repositoryToken == repositoryToken else { error = String(localized: "The repository changed. Reopen this preview."); return }
        perform("Recovering earlier management snapshot…") { _ = try await $0.restoreLegacyManagement(plan) }
    }
    func restoreManagementBackup(_ plan: RelatedManagementRestorePlan, request: RelatedAdministrationRequest) {
        guard request.repositoryToken == repositoryToken else { error = String(localized: "The repository changed. Reopen the restore preview."); return }
        perform("Restoring management backup…") { try await $0.restoreRelatedManagement(plan) }
    }
}
