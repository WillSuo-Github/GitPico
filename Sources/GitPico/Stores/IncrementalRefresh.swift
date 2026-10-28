import Foundation
import GitCore

enum MutationRefresh { case full, index, workingTree }
enum DeferredMetadata: Hashable, CaseIterable { case worktrees, submodules, workflow, remotes, stashes, organization }
protocol MutationRefreshReading: Sendable {
    func read(_ repository: GitRepository, previous: RepositorySnapshot, history: Bool, browser: Bool, ignored: Bool, rescanIgnored: Bool, options: HistoryOptions) async throws -> IncrementalSnapshot
}
struct GitMutationRefreshReader: MutationRefreshReading {
    func read(_ repository: GitRepository, previous: RepositorySnapshot, history: Bool, browser: Bool, ignored: Bool, rescanIgnored: Bool, options: HistoryOptions) async throws -> IncrementalSnapshot {
        try await repository.incrementalSnapshot(from: previous, history: history, browser: browser, ignored: ignored, rescanIgnored: rescanIgnored, options: options)
    }
}
extension RepositoryStore {
    func reloadIncrementally(history: Bool, includingRecovery: Bool = false) async throws {
        guard let repository, let previous = snapshot else { throw appFailure("Refresh the repository before updating its working copy.") }
        let token = repositoryToken
        metadataEpoch = UUID(); metadataTask?.cancel(); fileBrowserGeneration = UUID()
        let policyChanged = previous.changes.contains { $0.path == ".gitignore" || $0.path.hasSuffix("/.gitignore") }
        let delta = try await mutationRefreshReader.read(repository, previous: previous, history: history, browser: showAllFiles || showIgnoredFiles || showAssumeUnchanged, ignored: showIgnoredFiles, rescanIgnored: policyChanged, options: historyOptions)
        guard token == repositoryToken else { return }
        snapshot = delta.snapshot
        if let files = delta.browserFiles { workingFileEntries = files }
        let headChanged = history || delta.headChanged
        var refreshErrors: [String] = []
        metadataDirty.formUnion([.submodules, .workflow])
        if headChanged {
            clearHistoryCache()
            metadataDirty.formUnion(DeferredMetadata.allCases)
            do { undoAvailability = try await repository.undoAvailability() }
            catch { undoAvailability = nil; commitWarning = [commitWarning, String(localized: "The changes were saved, but Undo status could not be refreshed. \(error.localizedDescription)")].compactMap { $0 }.joined(separator: "\n") }
        }
        if includingRecovery || previous.operation != delta.snapshot.operation {
            do { rebaseProgress = delta.snapshot.operation == .rebase ? try await repository.rebaseProgress() : nil }
            catch { rebaseProgress = nil; refreshErrors.append(error.localizedDescription) }
            if !headChanged && previous.operation != delta.snapshot.operation {
                do { undoAvailability = try await repository.undoAvailability() }
                catch { undoAvailability = nil; refreshErrors.append(error.localizedDescription) }
            }
        }
        if includingRecovery {
            metadataDirty.insert(.worktrees)
            // Stashes and the recovery banner are visible outside their management destinations.
            // Publish them now; defer unrelated Worktree, submodule, LFS and Flow inspection.
            do {
                let values = try await repository.stashList()
                guard token == repositoryToken else { return }
                publishStashes(values); metadataDirty.remove(.stashes)
            } catch { metadataDirty.insert(.stashes); refreshErrors.append(error.localizedDescription) }
            do {
                let value = try await repository.automaticStashRecord()
                guard token == repositoryToken else { return }
                automaticStash = value
            } catch { refreshErrors.append(error.localizedDescription) }
        }
        guard token == repositoryToken else { return }
        if snapshot?.operation == RepositoryOperation.none { workingOnlyConflicts = false }
        await rebuildWorkingList()
        if let file = currentChange { selectChange(file, staged: file.isStaged && (!file.isUnstaged || stagedDiff)) }
        lastUpdated = Date()
        if isHistoryDestination { requestHistory() }
        requestDeferredMetadata(destination)
        if !refreshErrors.isEmpty { throw GitFailure(verbatim: refreshErrors.joined(separator: "\n")) }
    }
    private func publishStashes(_ values: [Stash]) {
        snapshot = snapshot?.replacingMetadata(stashes: values)
        if let selectedStash {
            self.selectedStash = values.first { $0.hash == selectedStash.hash && $0.subject == selectedStash.subject }
                ?? (destination == .stashes ? values.first : nil)
        }
    }
    func withFreshMetadata(_ scopes: Set<DeferredMetadata>, action: @escaping @MainActor () -> Void) {
        if metadataDirty.isDisjoint(with: scopes) { action(); return }
        let token = repositoryToken, epoch = metadataEpoch
        metadataTask = Task {
            await refreshDeferredMetadata(scopes)
            guard token == repositoryToken, epoch == metadataEpoch, !isBusy else { return }
            guard metadataDirty.isDisjoint(with: scopes) else {
                if error == nil {
                    let message = scopes.compactMap { scope -> String? in
                        switch scope { case .worktrees: worktreeError; case .submodules: submoduleError; case .workflow: workflowError; default: nil }
                    }.first
                    error = message ?? String(localized: "The requested repository data could not be refreshed. Try Refresh before continuing.")
                }
                return
            }
            action()
        }
    }
    func requestDeferredMetadata(_ destination: Destination) {
        let scopes: Set<DeferredMetadata>
        switch destination {
        case .worktrees: scopes = [.worktrees]
        case .submodules: scopes = [.submodules]
        case .repositorySettings: scopes = [.remotes, .organization, .workflow]
        case .stashes: scopes = [.stashes]
        case .branchesReview: scopes = [.worktrees, .remotes, .organization]
        case .history, .reference: scopes = [.organization]
        default: scopes = []
        }
        guard !metadataDirty.isDisjoint(with: scopes) else { return }
        metadataTask = Task { await refreshDeferredMetadata(scopes) }
    }
    func refreshDeferredMetadata(_ scopes: Set<DeferredMetadata>) async {
        guard let repository else { return }
        let token = repositoryToken, epoch = metadataEpoch
        for scope in scopes where metadataDirty.contains(scope) {
            do {
                switch scope {
                case .worktrees:
                    let values = try await repository.managedWorktrees(); guard token == repositoryToken && epoch == metadataEpoch else { return }; worktrees = values; worktreeError = nil
                case .submodules:
                    let values = try await repository.managedSubmodules(); guard token == repositoryToken && epoch == metadataEpoch else { return }; submodules = values; submoduleError = nil
                case .workflow:
                    await loadWorkflowState(); guard token == repositoryToken && epoch == metadataEpoch else { return }; if workflowError != nil { continue }
                case .remotes:
                    let values = try await repository.remoteConfigurations(); guard token == repositoryToken && epoch == metadataEpoch else { return }; managedRemotes = values; snapshot = snapshot?.replacingMetadata(remotes: values.map(\.name))
                case .stashes:
                    let values = try await repository.stashList(); guard token == repositoryToken && epoch == metadataEpoch else { return }; publishStashes(values)
                case .organization:
                    let value = try await repository.referenceOrganization(); guard token == repositoryToken && epoch == metadataEpoch else { return }; organization = value
                }
                guard token == repositoryToken && epoch == metadataEpoch else { return }
                metadataDirty.remove(scope)
            } catch {
                guard token == repositoryToken, epoch == metadataEpoch else { return }
                if scope == .worktrees { worktreeError = error.localizedDescription }
                else if scope == .submodules { submoduleError = error.localizedDescription }
                else { self.error = error.localizedDescription }
            }
        }
    }
}
