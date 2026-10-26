import Foundation
import GitCore

struct IntegrationRequest: Identifiable {
    let id = UUID()
    let action: GitRepository.Integration
    var revision: String?
    var expectedHead: HeadPosition? = nil
}

extension RepositoryStore {
    func createRepository(at url: URL, source: String?, recursive: Bool = false, allowLocalTransport: Bool = false, lfs: LFSCloneMode = .inherit, profileID: UUID? = nil) {
        guard !isBusy else { return }
        isBusy = true; activity = source == nil ? "Creating repository…" : "Cloning repository…"
        Task {
            do {
                let context = networkContext(profileID: profileID, useAssignment: false)
                let created = try await GitNetworkContexts.$current.withValue(context) {
                    try await GitRepository.create(at: url, source: source, recursive: recursive, allowLocalTransport: allowLocalTransport, lfs: lfs)
                }
                var assignmentWarning: String?
                if let profileID {
                    do { try authentication.assign(profileID, to: await created.root) }
                    catch { assignmentWarning = "Repository created, but the authentication assignment could not be saved. Choose the account again in Authentication. " + error.localizedDescription }
                }
                isBusy = false; activity = ""
                await open(url)
                if let assignmentWarning { self.error = assignmentWarning }
            } catch { isBusy = false; activity = ""; self.error = error.localizedDescription }
        }
    }

    func goBack() {
        guard (!isBusy || isBackgroundFetching), let target = backStack.popLast() else { return }
        forwardStack.append(destination); navigate(target, record: false)
    }
    func goForward() {
        guard (!isBusy || isBackgroundFetching), let target = forwardStack.popLast() else { return }
        backStack.append(destination); navigate(target, record: false)
    }
    func syncAll() {
        guard canSynchronize else { return }
        protectedPerform("Synchronizing…") { repository in
            try await repository.sync(.fetch)
            try await repository.sync(.pull)
            try await repository.sync(.push)
        }
    }

    func searchHistory() async {
        guard isHistoryDestination, historyOptions.query != search else { return }
        historyOptions.query = search; historyOptions.limit = 500
        requestHistory(debounce: .milliseconds(250))
    }

    func loadMoreHistory() {
        guard !isBusy, !isLoadingHistory, historyOptions.limit < 20_000 else { return }
        historyOptions.limit = min(20_000, historyOptions.limit + 500)
        requestHistory()
    }

    func stageChunk(_ hunkID: Int) {
        guard let change = currentChange, !ignoreWhitespace, !isLoadingDiff, diffError == nil, !diff.isEmpty else { return }
        let text = diff; let reverse = stagedDiff; let context = diffContext
        perform(reverse ? "Unstaging chunk…" : "Staging chunk…", refresh: .index) {
            try await $0.stageChunk(change, renderedDiff: text, hunkID: hunkID, reverse: reverse, context: context)
        }
    }

    func stageLines(_ selection: Set<PatchLineID>) {
        guard let change = currentChange, !ignoreWhitespace, !isLoadingDiff, diffError == nil, !selection.isEmpty else { return }
        let text = diff; let reverse = stagedDiff; let context = diffContext
        perform(reverse ? "Unstaging selected lines…" : "Staging selected lines…", refresh: .index) {
            try await $0.stageLines(change, renderedDiff: text, selection: selection, reverse: reverse, context: context)
        }
    }

    func resolveConflict(_ snapshot: ConflictSnapshot, resolution: ConflictResolution) {
        perform("Saving resolved file…", refresh: .workingTree) { [weak self] repository in
            try await repository.resolveConflict(snapshot, resolution: resolution)
            await self?.removeResolvedDraft(snapshot.path)
        }
    }
    private func removeResolvedDraft(_ path: String) { conflictDrafts.removeValue(forKey: path) }

    func updateAmend() {
        if !amend {
            if let draftBeforeAmend { commitSubject = draftBeforeAmend.0; commitBody = draftBeforeAmend.1 }
            draftBeforeAmend = nil
            return
        }
        guard amend, let repository else { return }
        draftBeforeAmend = (commitSubject, commitBody)
        let token = repositoryToken
        Task {
            do {
                let text = try await GitProcess.run(["show", "--no-show-signature", "-s", "--format=%B", "HEAD", "--"], at: repository.root).text.trimmingCharacters(in: .newlines)
                guard token == repositoryToken, amend else { return }
                let parts = text.components(separatedBy: "\n")
                commitSubject = parts.first ?? ""
                commitBody = parts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
            } catch { self.error = error.localizedDescription }
        }
    }

    func integrate(_ request: IntegrationRequest, revision: String, mainline: Int? = nil, expectedHead: HeadPosition? = nil) {
        protectedPerform("\(request.action.rawValue.capitalized)…", refresh: .workingTree) { try await $0.integrate(request.action, revision: revision, mainline: mainline, expectedHead: request.expectedHead ?? expectedHead) }
    }

    func abortOperation() { perform("Aborting operation…", refresh: .workingTree) { try await $0.abortOperation() } }
    func continueOperation() { perform("Continuing operation…", refresh: .workingTree) { try await $0.continueOperation() } }

    func loadConfiguration() async {
        guard let repository else { return }
        let token = repositoryToken, epoch = metadataEpoch
        do { let value = try await repository.configuration(); guard token == repositoryToken, epoch == metadataEpoch else { return }; configuration = value }
        catch { if token == repositoryToken, epoch == metadataEpoch { self.error = error.localizedDescription } }
    }

    func saveIdentity(name: String, email: String) {
        perform("Saving repository identity…") { try await $0.saveIdentity(name: name, email: email) }
    }
}
