import Foundation
import GitCore

extension RepositoryStore {
    func startAutomaticRefresh() {
        stopAutomaticRefresh()
        guard let repository else { return }
        let token = repositoryToken
        backgroundFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.repositoryToken == token else { return }
                if AppPreferences.shared.backgroundFetch, Date().timeIntervalSince(self.lastBackgroundFetch) >= 300 {
                    await self.fetchInBackground()
                }
            }
        }
        automaticMonitorTask = Task { [weak self] in
            do {
                let paths = try await repository.observationPaths()
                guard let self, !Task.isCancelled, self.repositoryToken == token else { return }
                self.fileMonitor = RepositoryFileMonitor(paths: paths) { [weak self] in
                    Task { @MainActor in
                        guard let self, self.repositoryToken == token else { return }
                        self.requestAutomaticRefresh()
                    }
                }
                if self.fileMonitor?.isRunning != true { self.automaticRefreshError = String(localized: "File monitoring could not start. Use Refresh to update this repository.") }
                else { self.requestAutomaticRefresh() } // Reconcile edits made while FSEvents was starting.
            } catch { self?.automaticRefreshError = error.localizedDescription }
        }
    }
    func stopAutomaticRefresh() {
        backgroundFetchTask?.cancel(); backgroundFetchTask = nil
        automaticMonitorTask?.cancel(); automaticMonitorTask = nil; fileMonitor = nil
        automaticRefreshTask?.cancel(); automaticRefreshTask = nil
        automaticRefreshPending = false; automaticRefreshEpoch = UUID()
    }
    func fetchInBackground() async {
        guard !isBusy, !isAutomaticallyRefreshing, let repository, snapshot?.remotes.isEmpty == false, let journal = networkActivity, let reservation = journal.reserveBackgroundFetch() else { return }
        let token = repositoryToken
        lastBackgroundFetch = Date(); isBackgroundFetching = true; isBusy = true; activity = String(localized: "Fetching remote updates…")
        defer { journal.releaseBackgroundFetch(reservation); isBackgroundFetching = false; isBusy = false; activity = ""; requestAutomaticRefresh() }
        var startedNetwork = false
        do {
            let custom = try await GitProcess.run(["config", "--get", "core.sshCommand"], at: repository.root, allowed: [0,1]).text.trimmingCharacters(in: .newlines)
            guard token == repositoryToken else { return }
            let base = networkContext()
            let ssh = ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] ?? (custom.isEmpty ? "/usr/bin/ssh" : custom)
            let context = GitNetworkContext(credential: base.credential, nonInteractive: true, sshCommand: ssh, observer: base.observer)
            startedNetwork = true
            try await GitNetworkContexts.$current.withValue(context) { try await repository.sync(.fetch) }
        } catch {
            if !startedNetwork {
                let root = await repository.root
                journal.receive(GitNetworkEvent(id: UUID(), command: "fetch", repository: root.lastPathComponent, repositoryPath: root.path, started: lastBackgroundFetch, phase: .failed, output: String(localized: "Background Fetch could not start. \(GitLogRedaction.clean(error.localizedDescription))"), cancellation: GitNetworkCancellation()))
            }
            // Started network failures remain in activity history without interrupting editing.
        }
    }
    func requestAutomaticRefresh() {
        guard repository != nil else { return }
        automaticRefreshPending = true
        guard !isBusy, !isAutomaticallyRefreshing, automaticRefreshTask == nil else { return }
        automaticRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self else { return }
            self.automaticRefreshTask = nil
            await self.refreshAutomatically()
        }
    }
    func refreshAutomatically() async {
        guard !isBusy, !isAutomaticallyRefreshing, let repository, let previous = snapshot else { return }
        let token = repositoryToken, epoch = automaticRefreshEpoch
        automaticRefreshPending = false; isAutomaticallyRefreshing = true
        defer {
            isAutomaticallyRefreshing = false
            if automaticRefreshPending { requestAutomaticRefresh() }
        }
        do {
            let value = try await repository.observedSnapshot(from: previous)
            guard !Task.isCancelled, token == repositoryToken, epoch == automaticRefreshEpoch, !isBusy else { return }
            let historyChanged = value.references != previous.references || value.head != previous.head
            let changesChanged = value.changes != previous.changes
            let metadataChanged = historyChanged || value.remotes != previous.remotes || value.stashes != previous.stashes || value.operation != previous.operation || value.identity.name != previous.identity.name || value.identity.email != previous.identity.email
            if changesChanged || metadataChanged || value.ahead != previous.ahead || value.behind != previous.behind { snapshot = value }
            if historyChanged || value.operation != previous.operation {
                let undo = try await repository.undoAvailability()
                let progress = value.operation == .rebase ? try await repository.rebaseProgress() : nil
                let recovery = try await repository.automaticStashRecord()
                guard token == repositoryToken, epoch == automaticRefreshEpoch, !isBusy else { return }
                undoAvailability = undo; rebaseProgress = progress; automaticStash = recovery
            }
            if metadataChanged {
                metadataEpoch = UUID(); metadataTask?.cancel(); metadataDirty.formUnion(DeferredMetadata.allCases)
            } else { metadataDirty.formUnion([.submodules, .workflow]) }
            if historyChanged { clearHistoryCache() }
            if showAllFiles || showIgnoredFiles || showAssumeUnchanged {
                let files = try await repository.workingFiles(includeIgnored: showIgnoredFiles)
                guard token == repositoryToken, epoch == automaticRefreshEpoch, !isBusy else { return }
                workingFileEntries = files
            }
            if changesChanged || historyChanged || showAllFiles || showIgnoredFiles || showAssumeUnchanged { await rebuildWorkingList() }
            guard token == repositoryToken, epoch == automaticRefreshEpoch, !isBusy else { return }
            if let file = currentChange, !file.isConflicted {
                workingDiffRequest = nil
                selectChange(file, staged: file.isStaged && (!file.isUnstaged || stagedDiff))
            }
            if historyChanged, isHistoryDestination { requestHistory() }
            requestDeferredMetadata(destination)
            lastUpdated = Date(); automaticRefreshError = nil
        } catch {
            guard token == repositoryToken, epoch == automaticRefreshEpoch else { return }
            automaticRefreshError = error.localizedDescription
        }
    }
}
