import Foundation
import GitCore

private struct ClosedRepositoryFetchTarget: Sendable {
    let repository: GitRepository
    let root: URL
    let commonDirectory: String?
}

extension RepositoryWorkspace {
    static func canonicalRepositoryPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    func startBackgroundFetchScheduler(initialDelay: Duration? = nil) {
        guard monitoringEnabled, !isShuttingDown, !isSystemAsleep else { return }
        backgroundFetchSchedulerTask?.cancel()
        backgroundFetchSchedulerTask = nil
        guard preferences.backgroundFetchInterval.isEnabled else { return }
        let firstDelay = initialDelay ?? backgroundFetchPollInterval
        backgroundFetchSchedulerTask = Task { [weak self] in
            var nextDelay = firstDelay
            while !Task.isCancelled {
                do { try await Task.sleep(for: nextDelay) } catch { return }
                guard let self, !Task.isCancelled else { return }
                nextDelay = self.backgroundFetchPollInterval
                await self.runDueBackgroundFetches()
            }
        }
    }

    func stopBackgroundFetch() {
        backgroundFetchSchedulerTask?.cancel()
        backgroundFetchSchedulerTask = nil
        activeBackgroundFetchTask?.cancel()
        networkActivity.cancelBackgroundFetch()
    }

    func waitForBackgroundFetchToStop(timeout: Duration = .seconds(2)) async {
        stopBackgroundFetch()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        if let task = activeBackgroundFetchTask {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(for: timeout) }
                await group.next()
                group.cancelAll()
            }
        }
        while (networkActivity.hasBackgroundReservation || (networkActivity.runningCount > 0 && networkActivity.foregroundRunningCount == 0)) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func handleBackgroundFetchPreferenceChange() {
        guard monitoringEnabled, !isShuttingDown, !isSystemAsleep else { return }
        if !preferences.backgroundFetchInterval.isEnabled {
            stopBackgroundFetch()
            return
        }
        let delay = min(backgroundFetchPollInterval, .seconds(2))
        startBackgroundFetchScheduler(initialDelay: delay)
    }

    func recordBackgroundFetch(for path: String, commonDirectory: String? = nil) {
        let normalized = Self.canonicalRepositoryPath(path)
        let now = backgroundFetchNow()
        lastBackgroundFetchByPath[normalized] = now
        if let commonDirectory {
            lastBackgroundFetchByCommonDir[Self.canonicalRepositoryPath(commonDirectory)] = now
        }
    }

    func backgroundFetchCandidates() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        func append(_ path: String) {
            let normalized = Self.canonicalRepositoryPath(path)
            guard seen.insert(normalized).inserted else { return }
            ordered.append(normalized)
        }
        if let activeRoot = activeTab.root { append(activeRoot.path) }
        for tab in tabs where tab.id != activeTab.id {
            if let root = tab.root { append(root.path) }
        }
        for path in library.recentPaths { append(path) }
        for entry in library.document.repositories { append(entry.path) }
        return ordered
    }

    func runDueBackgroundFetches() async {
        if let active = activeBackgroundFetchTask {
            await active.value
        }
        guard !Task.isCancelled, !isShuttingDown, !isSystemAsleep, preferences.backgroundFetchInterval.isEnabled else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performBackgroundFetchSweep()
        }
        activeBackgroundFetchTask = task
        await task.value
        if activeBackgroundFetchTask == task {
            activeBackgroundFetchTask = nil
        }
    }

    private func performBackgroundFetchSweep() async {
        guard !isShuttingDown, !isSystemAsleep, preferences.backgroundFetchInterval.isEnabled else { return }
        let candidates = backgroundFetchCandidates()
        pruneBackgroundFetchHistory(keeping: Set(candidates))
        for path in candidates {
            guard !Task.isCancelled, !isShuttingDown, !isSystemAsleep, let interval = preferences.backgroundFetchInterval.seconds else { return }
            let now = backgroundFetchNow()
            if let last = lastBackgroundFetchByPath[path], now.timeIntervalSince(last) < interval {
                continue
            }
            guard networkActivity.runningCount == 0, !tabs.contains(where: \.isOpening) else { return }
            await fetchRepositoryInBackground(at: path, interval: interval)
        }
    }

    private func fetchRepositoryInBackground(at path: String, interval: TimeInterval) async {
        if let openTab = openTabForPath(path) {
            if openTab.isOpening { return }
            if let snapshot = openTab.store.snapshot, let repository = openTab.store.repository {
                guard !openTab.store.isBusy, !openTab.store.isFetching, !openTab.store.isAutomaticallyRefreshing else { return }
                if snapshot.remotes.isEmpty {
                    lastBackgroundFetchByPath[path] = backgroundFetchNow()
                    return
                }
                let commonDir = try? await repository.commonDirectory().path
                guard !Task.isCancelled, !isShuttingDown, !isSystemAsleep, preferences.backgroundFetchInterval.isEnabled else { return }
                if let commonDir, let lastCommon = lastBackgroundFetchByCommonDir[commonDir], backgroundFetchNow().timeIntervalSince(lastCommon) < interval {
                    lastBackgroundFetchByPath[path] = lastCommon
                    return
                }
                let ran = await openTab.store.performBackgroundFetch(allowWhileChoosingRepository: true)
                guard ran, !Task.isCancelled, !isShuttingDown, !isSystemAsleep, preferences.backgroundFetchInterval.isEnabled else { return }
                recordBackgroundFetch(for: path, commonDirectory: commonDir)
                return
            }
        }

        guard let target = await Self.inspectClosedRepository(at: path) else {
            guard !Task.isCancelled, !isShuttingDown, !isSystemAsleep, preferences.backgroundFetchInterval.isEnabled else { return }
            lastBackgroundFetchByPath[path] = backgroundFetchNow()
            return
        }
        guard !Task.isCancelled, !isShuttingDown, !isSystemAsleep, preferences.backgroundFetchInterval.isEnabled else { return }
        if let commonDir = target.commonDirectory, let lastCommon = lastBackgroundFetchByCommonDir[commonDir], backgroundFetchNow().timeIntervalSince(lastCommon) < interval {
            lastBackgroundFetchByPath[path] = lastCommon
            return
        }
        if let openedMidInspection = openTabForPath(path), openedMidInspection.isOpening || openedMidInspection.store.snapshot != nil {
            return
        }
        guard let reservation = networkActivity.reserveBackgroundFetch() else { return }
        let started = Date()
        backgroundFetchStartedAt = started
        backgroundFetchingRepositoryPath = target.root.path
        defer {
            networkActivity.releaseBackgroundFetch(reservation)
            backgroundFetchingRepositoryPath = nil
            refreshOpenTabs(matching: target.root.path)
        }

        var startedNetwork = false
        do {
            let custom = try await GitProcess.run(["config", "--get", "core.sshCommand"], at: target.root, allowed: [0, 1], timeout: 10).text.trimmingCharacters(in: .newlines)
            guard !Task.isCancelled, !isShuttingDown, !isSystemAsleep, preferences.backgroundFetchInterval.isEnabled else { return }
            let ssh = ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] ?? (custom.isEmpty ? "/usr/bin/ssh" : custom)
            let context = authentication.networkContext(
                activity: networkActivity,
                nonInteractive: true,
                sshCommand: ssh,
                backgroundReservation: reservation
            )
            startedNetwork = true
            try await GitNetworkContexts.$current.withValue(context) {
                try await target.repository.sync(.fetch, timeout: 120)
            }
        } catch {
            if !startedNetwork, !Task.isCancelled {
                networkActivity.receive(GitNetworkEvent(
                    id: UUID(),
                    command: "fetch",
                    repository: target.root.lastPathComponent,
                    repositoryPath: target.root.path,
                    started: started,
                    phase: .failed,
                    output: String(localized: "Background Fetch could not start. \(GitLogRedaction.clean(error.localizedDescription))"),
                    cancellation: GitNetworkCancellation()
                ))
            }
        }
        guard !Task.isCancelled, !isShuttingDown, !isSystemAsleep, preferences.backgroundFetchInterval.isEnabled else { return }
        recordBackgroundFetch(for: path, commonDirectory: target.commonDirectory)
    }

    private func openTabForPath(_ normalizedPath: String) -> RepositoryTab? {
        tabs.first { tab in
            guard let root = tab.root else { return false }
            return Self.canonicalRepositoryPath(root.path) == normalizedPath
        }
    }

    private func refreshOpenTabs(matching rootPath: String) {
        let normalized = Self.canonicalRepositoryPath(rootPath)
        for tab in tabs where tab.root != nil {
            if let root = tab.root, Self.canonicalRepositoryPath(root.path) == normalized, tab.store.snapshot != nil {
                tab.store.requestAutomaticRefresh()
            }
        }
    }

    private func pruneBackgroundFetchHistory(keeping activePaths: Set<String>) {
        lastBackgroundFetchByPath = lastBackgroundFetchByPath.filter { activePaths.contains($0.key) }
        let now = backgroundFetchNow()
        let maxWindow = TimeInterval(BackgroundFetchInterval.everyHour.rawValue)
        lastBackgroundFetchByCommonDir = lastBackgroundFetchByCommonDir.filter { now.timeIntervalSince($0.value) < maxWindow }
    }

    private nonisolated static func inspectClosedRepository(at normalizedPath: String) async -> ClosedRepositoryFetchTarget? {
        let folderState = await Task.detached(priority: .utility) { RepositoryFolderState.read(path: normalizedPath) }.value
        guard folderState == .available, !Task.isCancelled else { return nil }
        let folderURL = URL(fileURLWithPath: normalizedPath, isDirectory: true)
        guard let repository = try? await GitRepository.open(folderURL) else { return nil }
        let root = await repository.root
        guard root.standardizedFileURL.resolvingSymlinksInPath().path == normalizedPath, !Task.isCancelled else { return nil }
        guard let remotesOutput = try? await GitProcess.run(["remote"], at: root, timeout: 10),
              remotesOutput.text.split(whereSeparator: \.isNewline).isEmpty == false else {
            return nil
        }
        let commonDirectory = try? await repository.commonDirectory().path
        return ClosedRepositoryFetchTarget(repository: repository, root: root, commonDirectory: commonDirectory)
    }
}
