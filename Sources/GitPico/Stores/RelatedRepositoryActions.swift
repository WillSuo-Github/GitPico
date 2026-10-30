import Foundation
import GitCore

enum WorktreeAction { case create(String?), move(ManagedWorktree), repair(ManagedWorktree), remove(ManagedWorktree), lock(ManagedWorktree), unlock(ManagedWorktree) }
struct WorktreeRequest: Identifiable { let id = UUID(); let repositoryToken: UUID; let action: WorktreeAction }
enum SubmoduleAction { case add, manage(ManagedSubmodule, SubmoduleOperation) }
struct SubmoduleRequest: Identifiable { let id = UUID(); let repositoryToken: UUID; let action: SubmoduleAction }

extension RepositoryStore {
    func loadRelatedRepositories() async {
        guard let repository else { return }; let token = repositoryToken, epoch = metadataEpoch
        do { let entries = try await repository.managedWorktrees(); if token == repositoryToken && epoch == metadataEpoch { worktrees = entries; worktreeError = nil; metadataDirty.remove(.worktrees) } } catch { if token == repositoryToken && epoch == metadataEpoch { metadataDirty.insert(.worktrees); worktrees = []; worktreeError = error.localizedDescription } }
        do { let entries = try await repository.managedSubmodules(); if token == repositoryToken && epoch == metadataEpoch { submodules = entries; submoduleError = nil; metadataDirty.remove(.submodules) } } catch { if token == repositoryToken && epoch == metadataEpoch { metadataDirty.insert(.submodules); submodules = []; submoduleError = error.localizedDescription } }
    }
    func manageWorktree(_ action: WorktreeAction) {
        guard !isBusy, repository != nil else { return }
        if !metadataDirty.contains(.worktrees) { worktreeRequest = WorktreeRequest(repositoryToken: repositoryToken, action: action); return }
        withFreshMetadata([.worktrees]) {
            let current: WorktreeAction
            switch action {
            case .create: current = action
            case .move(let old), .repair(let old), .remove(let old), .lock(let old), .unlock(let old):
                guard let entry = self.worktrees.first(where: { $0.path == old.path }) else { self.error = String(localized: "This worktree is no longer available. Refresh the worktree list."); return }
                switch action { case .move: current = .move(entry); case .repair: current = .repair(entry); case .remove: current = .remove(entry); case .lock: current = .lock(entry); default: current = .unlock(entry) }
            }
            self.worktreeRequest = WorktreeRequest(repositoryToken: self.repositoryToken, action: current)
        }
    }
    func manageSubmodule(_ action: SubmoduleAction) {
        guard !isBusy, repository != nil else { return }
        if !metadataDirty.contains(.submodules) { submoduleRequest = SubmoduleRequest(repositoryToken: repositoryToken, action: action); return }
        withFreshMetadata([.submodules]) {
            var current = action
            if case .manage(let old, let operation) = action {
                guard let entry = self.submodules.first(where: { $0.path == old.path }) else { self.error = String(localized: "This submodule is no longer available. Refresh the submodule list."); return }
                current = .manage(entry, operation)
            }
            self.submoduleRequest = SubmoduleRequest(repositoryToken: self.repositoryToken, action: current)
        }
    }
    func openWorktree(_ record: ManagedWorktree, inNewTab: Bool = false) {
        guard !isBusy, let repository else { return }
        guard inNewTab || record.path != snapshot?.root.path else { return }
        isBusy = true; activity = String(localized: "Opening worktree…")
        operationTask = Task {
            do {
                let child = try await repository.checkedWorktree(record); let url = await child.root
                isBusy = false
                if inNewTab, let workspace {
                    let tab = workspace.newTab(from: workspace.tab(for: self)?.id)
                    await workspace.open(url, from: tab.store)
                } else { await open(url) }
            }
            catch { self.error = error.localizedDescription; isBusy = false }
            activity = ""
        }
    }
    func openSubmodule(_ record: ManagedSubmodule) {
        guard !isBusy, let repository else { return }
        isBusy = true; activity = String(localized: "Opening submodule…")
        operationTask = Task {
            do { let child = try await repository.checkedSubmodule(record); let url = await child.root; isBusy = false; await open(url) }
            catch { self.error = error.localizedDescription; isBusy = false }
            activity = ""
        }
    }
    func applyWorktreePlan(_ plan: WorktreeCreationPlan, request: WorktreeRequest, openAfter: Bool) {
        guard !isBusy, let repository, request.repositoryToken == repositoryToken else { error = String(localized: "The repository changed. Reopen the preview."); return }
        isBusy = true; activity = String(localized: "Creating worktree…")
        Task {
            do {
                let record = try await repository.createWorktree(plan)
                try await reload(); isBusy = false
                if openAfter { await open(URL(fileURLWithPath: record.path)) }
            } catch { self.error = error.localizedDescription; try? await reload(); isBusy = false }
            activity = ""
        }
    }
    func applySubmodulePlan(_ plan: SubmodulePlan, request: SubmoduleRequest) {
        guard request.repositoryToken == repositoryToken else { error = String(localized: "The repository changed. Reopen the preview."); return }
        perform("\(plan.operation.actionTitle)") { try await $0.applySubmodule(plan) }
    }
    func addSubmodulePlan(_ plan: SubmoduleAdditionPlan, request: SubmoduleRequest) {
        guard request.repositoryToken == repositoryToken else { error = String(localized: "The repository changed. Reopen the preview."); return }
        perform("Adding submodule…") { try await $0.addSubmodule(plan) }
    }
}
