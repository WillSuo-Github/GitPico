import Foundation
import GitCore

enum RepositoryInfrastructureMode: String, CaseIterable { case move = "Move Main Repository", repair = "Repair Pointers", history = "Migration / Repair History" }
struct RepositoryInfrastructureRequest: Identifiable {
    let id = UUID()
    let repositoryToken: UUID
    let mode: RepositoryInfrastructureMode
}
extension RepositoryStore {
    func infrastructure(_ mode: RepositoryInfrastructureMode) {
        guard !isBusy else { return }
        infrastructureRequest = RepositoryInfrastructureRequest(repositoryToken: repositoryToken, mode: mode)
    }
    func migrateMain(_ plan: MainRepositoryMigrationPlan, request: RepositoryInfrastructureRequest) {
        guard !isBusy, request.repositoryToken == repositoryToken else { error = "The repository changed. Reopen the migration preview."; return }
        isBusy = true; activity = "Moving main repository and reconnecting worktrees…"
        Task {
            do {
                let moved = try await GitRepository.open(plan.source).migrateMainRepository(plan)
                do { try library.relocatePrefix(from: plan.source.path, to: plan.destination.path) }
                catch { self.error = "The repository moved, but saved registrations need review: " + error.localizedDescription }
                let url = await moved.root; isBusy = false; await open(url)
            } catch { self.error = error.localizedDescription; isBusy = false }
            activity = ""
        }
    }
    func repairPointers(_ plan: PointerRepairPlan, request: RepositoryInfrastructureRequest) {
        guard !isBusy, request.repositoryToken == repositoryToken else { error = "The repository changed. Reopen the pointer preview."; return }
        isBusy = true; activity = "Repairing repository pointers…"
        Task {
            do { _ = try await GitRepository(root: plan.mainRoot).applyPointerRepair(plan); isBusy = false; await open(plan.mainRoot) }
            catch { self.error = error.localizedDescription; isBusy = false }
            activity = ""
        }
    }
    func recoverSavedMain(_ plan: MainRepositoryRecoveryPlan, request: RepositoryInfrastructureRequest) {
        guard !isBusy, request.repositoryToken == repositoryToken else { error = "The repository changed. Reopen this recovery preview."; return }
        isBusy = true; activity = "Recovering saved repository into a new folder…"
        Task {
            do { let recovered = try await GitRepository(root: URL(fileURLWithPath: plan.backup.destination)).recoverSavedMainRepository(plan); let url = await recovered.root; isBusy = false; await open(url) }
            catch { self.error = error.localizedDescription; isBusy = false }
            activity = ""
        }
    }
    func restoreMainMigration(_ plan: MainMigrationRestorePlan, request: RepositoryInfrastructureRequest) {
        guard !isBusy, request.repositoryToken == repositoryToken else { error = "The repository changed. Reopen this recovery preview."; return }
        isBusy = true; activity = "Restoring main repository migration…"
        Task {
            do {
                let restored = try await GitRepository(root: URL(fileURLWithPath: plan.backup.destination)).restoreMainRepositoryMigration(plan)
                do { try library.relocatePrefix(from: plan.backup.destination, to: plan.backup.source) }
                catch { self.error = "Repository restored, but saved registrations need review: " + error.localizedDescription }
                let url = await restored.root; isBusy = false; await open(url)
            } catch {
                self.error = error.localizedDescription; isBusy = false
                let source = URL(fileURLWithPath: plan.backup.source)
                if FileManager.default.fileExists(atPath: source.appendingPathComponent(".git").path) {
                    try? library.relocatePrefix(from: plan.backup.destination, to: plan.backup.source)
                    await open(source)
                }
            }
            activity = ""
        }
    }
    func resumePointerRepair(_ record: PointerRepairBackup, undo: Bool, request: RepositoryInfrastructureRequest) {
        guard !isBusy, request.repositoryToken == repositoryToken else { error = "The repository changed. Reopen this repair history."; return }
        isBusy = true; activity = undo ? "Restoring pointer metadata…" : "Resuming pointer repair…"
        Task {
            do { try await GitRepository(root: URL(fileURLWithPath: record.mainPath)).resumePointerRepair(record, undo: undo); isBusy = false; await open(URL(fileURLWithPath: record.mainPath)) }
            catch { self.error = error.localizedDescription; isBusy = false }
            activity = ""
        }
    }
}
