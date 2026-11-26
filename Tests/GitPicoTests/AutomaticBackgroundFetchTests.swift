import Foundation
import GitCore
import Synchronization
import Testing
@testable import GitPico

@MainActor private func waitForCondition(
    timeout: TimeInterval = 15,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), sourceLocation: sourceLocation)
}

private struct RemoteBackedRepo {
    let local: URL
    let remote: URL
    let peer: URL

    static func make(in base: URL, name: String, uploadPackGate: URL? = nil) async throws -> Self {
        let local = base.appendingPathComponent(name, isDirectory: true)
        let remote = base.appendingPathComponent("\(name).git", isDirectory: true)
        let peer = base.appendingPathComponent("\(name)-peer", isDirectory: true)
        _ = try await GitRepository.create(at: local)
        try await configure(local)
        try Data("initial \(name)\n".utf8).write(to: local.appendingPathComponent("file.txt"))
        _ = try await GitProcess.run(["add", "file.txt"], at: local)
        _ = try await GitProcess.run(["commit", "-m", "Initial \(name)"], at: local)
        _ = try await GitProcess.run(["init", "--bare", remote.path], at: base)
        _ = try await GitProcess.run(["remote", "add", "origin", remote.path], at: local)
        _ = try await GitProcess.run(["push", "-u", "origin", "main"], at: local)
        _ = try await GitProcess.run(["clone", "--branch", "main", remote.path, peer.path], at: base)
        try await configure(peer)
        if let uploadPackGate {
            let helper = base.appendingPathComponent("upload-pack-\(name).sh")
            let script = """
            #!/bin/sh
            count=0
            while [ ! -f "\(uploadPackGate.path)" ] && [ "$count" -lt 600 ]; do
                sleep 0.05
                count=$((count + 1))
            done
            exec /usr/bin/git upload-pack "$@"
            """
            try Data(script.utf8).write(to: helper)
            _ = try await GitProcess.run(["config", "remote.origin.uploadpack", "/bin/sh '" + helper.path + "'"], at: local)
        }
        return Self(local: local.resolvingSymlinksInPath(), remote: remote.resolvingSymlinksInPath(), peer: peer.resolvingSymlinksInPath())
    }

    func pushRemoteCommit(content: String, message: String) async throws -> String {
        try Data(content.utf8).write(to: peer.appendingPathComponent("file.txt"))
        _ = try await GitProcess.run(["add", "file.txt"], at: peer)
        _ = try await GitProcess.run(["commit", "-m", message], at: peer)
        _ = try await GitProcess.run(["push", "origin", "main"], at: peer)
        return try await GitProcess.run(["rev-parse", "HEAD"], at: peer).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remoteTrackingHash(at directory: URL? = nil) async throws -> String {
        try await GitProcess.run(["rev-parse", "refs/remotes/origin/main"], at: directory ?? local).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func configure(_ directory: URL) async throws {
        for (key, value) in [
            ("user.name", "Background Fetch Test"),
            ("user.email", "background-fetch@example.invalid"),
            ("commit.gpgsign", "false"),
            ("core.hooksPath", "/dev/null")
        ] {
            _ = try await GitProcess.run(["config", key, value], at: directory)
        }
    }
}

@Test @MainActor func backgroundFetchPreferencesPersistAndMigrateLegacySetting() throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("GitPico-prefs-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let freshFile = directory.appendingPathComponent("fresh.json")
    let fresh = AppPreferences(file: freshFile)
    #expect(fresh.backgroundFetchInterval == .off)

    let notificationCount = Mutex(0)
    let observer = NotificationCenter.default.addObserver(
        forName: AppPreferences.backgroundFetchIntervalDidChangeNotification,
        object: fresh,
        queue: nil
    ) { _ in notificationCount.withLock { $0 += 1 } }
    defer { NotificationCenter.default.removeObserver(observer) }

    fresh.backgroundFetchInterval = .every15Minutes
    #expect(notificationCount.withLock { $0 } == 1)
    fresh.backgroundFetchInterval = .every15Minutes
    #expect(notificationCount.withLock { $0 } == 1)

    let reloaded = AppPreferences(file: freshFile)
    #expect(reloaded.backgroundFetchInterval == .every15Minutes)

    let legacyEnabledFile = directory.appendingPathComponent("legacy-enabled.json")
    try JSONEncoder().encode(["backgroundFetch": 1.0]).write(to: legacyEnabledFile)
    #expect(AppPreferences(file: legacyEnabledFile).backgroundFetchInterval == .every5Minutes)

    let legacyDisabledFile = directory.appendingPathComponent("legacy-disabled.json")
    try JSONEncoder().encode(["backgroundFetch": 0.0]).write(to: legacyDisabledFile)
    #expect(AppPreferences(file: legacyDisabledFile).backgroundFetchInterval == .off)
}

@Test @MainActor func workspaceBackgroundFetchUpdatesOpenAndClosedSavedRepositories() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("GitPico-bgfetch-all-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let openRepo = try await RemoteBackedRepo.make(in: root, name: "OpenRepo")
    let closedRepo = try await RemoteBackedRepo.make(in: root, name: "ClosedRepo")
    let library = RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: [])
    _ = try library.register(openRepo.local)
    _ = try library.register(closedRepo.local)
    let preferences = AppPreferences(file: root.appendingPathComponent("preferences.json"))
    preferences.backgroundFetchInterval = .every5Minutes

    let workspace = RepositoryWorkspace(library: library, draftsFile: root.appendingPathComponent("drafts.json"), preferences: preferences)
    defer { workspace.shutdown() }
    await workspace.open(openRepo.local)
    try Data("local edit\n".utf8).write(to: openRepo.local.appendingPathComponent("file.txt"))

    let openRemoteHash = try await openRepo.pushRemoteCommit(content: "remote open\n", message: "Remote open update")
    let closedRemoteHash = try await closedRepo.pushRemoteCommit(content: "remote closed\n", message: "Remote closed update")

    await workspace.runDueBackgroundFetches()

    #expect(try await openRepo.remoteTrackingHash() == openRemoteHash)
    #expect(try await closedRepo.remoteTrackingHash() == closedRemoteHash)
    #expect(try String(contentsOf: openRepo.local.appendingPathComponent("file.txt"), encoding: .utf8) == "local edit\n")
    try await waitForCondition { workspace.activeStore.snapshot?.behind == 1 }

    let fetchedPaths = Set(workspace.networkActivity.records.filter { $0.command == "fetch" && $0.phase == .succeeded }.compactMap(\.repositoryPath))
    #expect(fetchedPaths == [openRepo.local.path, closedRepo.local.path])
}

@Test @MainActor func workspaceBackgroundFetchRespectsIntervalAndSkipsInvalidOrDuplicateRepos() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("GitPico-bgfetch-interval-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let mainRepo = try await RemoteBackedRepo.make(in: root, name: "MainRepo")
    let linkedWorktree = root.appendingPathComponent("LinkedWorktree", isDirectory: true)
    _ = try await GitProcess.run(["worktree", "add", "-b", "linked", linkedWorktree.path], at: mainRepo.local)

    let localOnly = root.appendingPathComponent("LocalOnly", isDirectory: true)
    _ = try await GitRepository.create(at: localOnly)

    let missingRepo = root.appendingPathComponent("MissingRepo", isDirectory: true)
    _ = try await GitRepository.create(at: missingRepo)

    let subfolder = mainRepo.local.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

    let library = RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: [])
    _ = try library.register(mainRepo.local)
    _ = try library.register(linkedWorktree)
    _ = try library.register(localOnly)
    _ = try library.register(missingRepo)
    _ = try library.register(subfolder)
    try FileManager.default.removeItem(at: missingRepo)

    let preferences = AppPreferences(file: root.appendingPathComponent("preferences.json"))
    preferences.backgroundFetchInterval = .every5Minutes

    var currentTime = Date(timeIntervalSince1970: 1_000_000)
    let workspace = RepositoryWorkspace(library: library, draftsFile: root.appendingPathComponent("drafts.json"), preferences: preferences)
    defer { workspace.shutdown() }
    workspace.backgroundFetchNow = { currentTime }

    let firstHash = try await mainRepo.pushRemoteCommit(content: "remote 1\n", message: "Remote 1")
    await workspace.runDueBackgroundFetches()

    #expect(try await mainRepo.remoteTrackingHash() == firstHash)
    #expect(try await mainRepo.remoteTrackingHash(at: linkedWorktree) == firstHash)
    #expect(workspace.networkActivity.records.count == 1)
    #expect(workspace.networkActivity.records.first?.phase == .succeeded)

    let secondHash = try await mainRepo.pushRemoteCommit(content: "remote 2\n", message: "Remote 2")
    currentTime = currentTime.addingTimeInterval(299)
    await workspace.runDueBackgroundFetches()
    #expect(workspace.networkActivity.records.count == 1)
    #expect(try await mainRepo.remoteTrackingHash() == firstHash)

    currentTime = currentTime.addingTimeInterval(2)
    await workspace.runDueBackgroundFetches()
    #expect(workspace.networkActivity.records.count == 2)
    #expect(try await mainRepo.remoteTrackingHash() == secondHash)
}

@Test @MainActor func preferenceToggleAndSleepCancelInFlightBackgroundFetchAndResumeAfterWake() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("GitPico-bgfetch-lifecycle-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let gate = root.appendingPathComponent("release-fetch.gate")
    defer { try? Data().write(to: gate) }
    let slowRepo = try await RemoteBackedRepo.make(in: root, name: "SlowRepo", uploadPackGate: gate)
    let expectedHash = try await slowRepo.pushRemoteCommit(content: "after wake\n", message: "After wake")
    let library = RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: [])
    _ = try library.register(slowRepo.local)

    let preferences = AppPreferences(file: root.appendingPathComponent("preferences.json"))
    let workspace = RepositoryWorkspace(library: library, draftsFile: root.appendingPathComponent("drafts.json"), preferences: preferences)
    defer { workspace.shutdown() }
    workspace.backgroundFetchPollInterval = .milliseconds(30)
    workspace.startMonitoring()

    try await Task.sleep(for: .milliseconds(80))
    #expect(workspace.networkActivity.records.isEmpty)

    preferences.backgroundFetchInterval = .every5Minutes
    try await waitForCondition { workspace.backgroundFetchingRepositoryPath == slowRepo.local.path && workspace.networkActivity.runningCount == 1 }
    #expect(workspace.networkActivity.foregroundRunningCount == 0)

    preferences.backgroundFetchInterval = .off
    try await waitForCondition { !workspace.hasActiveBackgroundFetch && workspace.networkActivity.runningCount == 0 }
    #expect(workspace.networkActivity.records.first?.phase == .cancelled)

    preferences.backgroundFetchInterval = .every5Minutes
    try await waitForCondition { workspace.backgroundFetchingRepositoryPath == slowRepo.local.path && workspace.networkActivity.runningCount == 1 }
    workspace.prepareForSleep()
    try await waitForCondition { !workspace.hasActiveBackgroundFetch && workspace.networkActivity.runningCount == 0 }
    #expect(workspace.networkActivity.records.first?.phase == .cancelled)

    _ = try await GitProcess.run(["config", "--unset", "remote.origin.uploadpack"], at: slowRepo.local)
    workspace.resumeAfterWake()
    try await waitForCondition { workspace.networkActivity.records.first?.phase == .succeeded }
    #expect(try await slowRepo.remoteTrackingHash() == expectedHash)
}

@Test @MainActor func manualAllRemotesFetchResetsBackgroundFetchSchedule() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("GitPico-bgfetch-manual-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let repo = try await RemoteBackedRepo.make(in: root, name: "ManualRepo")
    let library = RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: [])
    _ = try library.register(repo.local)
    let preferences = AppPreferences(file: root.appendingPathComponent("preferences.json"))
    preferences.backgroundFetchInterval = .every5Minutes

    let workspace = RepositoryWorkspace(library: library, draftsFile: root.appendingPathComponent("drafts.json"), preferences: preferences)
    defer { workspace.shutdown() }
    await workspace.open(repo.local)

    let firstHash = try await repo.pushRemoteCommit(content: "manual fetch\n", message: "Manual fetch")
    workspace.activeStore.sync(.fetch)
    await workspace.activeStore.fetchTask?.value
    #expect(try await repo.remoteTrackingHash() == firstHash)
    let countAfterManual = workspace.networkActivity.records.count

    await workspace.runDueBackgroundFetches()
    #expect(workspace.networkActivity.records.count == countAfterManual)
}

@Test @MainActor func openingClosedRepositoryDuringWorkspaceBackgroundFetchGuardsAndRefreshes() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("GitPico-bgfetch-openmid-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let gate = root.appendingPathComponent("release-openmid.gate")
    defer { try? Data().write(to: gate) }
    let repo = try await RemoteBackedRepo.make(in: root, name: "OpenMidRepo", uploadPackGate: gate)
    let remoteHash = try await repo.pushRemoteCommit(content: "mid open update\n", message: "Mid open update")
    let library = RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: [])
    _ = try library.register(repo.local)
    let preferences = AppPreferences(file: root.appendingPathComponent("preferences.json"))
    preferences.backgroundFetchInterval = .every5Minutes

    let workspace = RepositoryWorkspace(library: library, draftsFile: root.appendingPathComponent("drafts.json"), preferences: preferences)
    defer { workspace.shutdown() }

    let sweep = Task { await workspace.runDueBackgroundFetches() }
    try await waitForCondition { workspace.backgroundFetchingRepositoryPath == repo.local.path && workspace.networkActivity.runningCount == 1 }

    await workspace.open(repo.local)
    #expect(workspace.activeStore.isWorkspaceBackgroundFetchingCurrentRepository)
    #expect(workspace.activeStore.isActiveBackgroundFetching)
    #expect(workspace.activeStore.isFetching && !workspace.activeStore.canFetch && !workspace.activeStore.canRemoteIntegrate)
    #expect(workspace.activeStore.activeFetchNetworkRecord?.repositoryPath == repo.local.path)

    try Data().write(to: gate)
    await sweep.value
    #expect(!workspace.activeStore.isFetching && !workspace.activeStore.isActiveBackgroundFetching)
    #expect(try await repo.remoteTrackingHash() == remoteHash)
    try await waitForCondition { workspace.activeStore.snapshot?.behind == 1 }
}
