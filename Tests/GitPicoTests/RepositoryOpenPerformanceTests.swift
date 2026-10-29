import AppKit
import Foundation
import GitCore
import Testing
@testable import GitPico

@Test @MainActor func repositoryOpenKeepsSupplementalStateAndWorkingFilesReady() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let root = await f.repository.root
    let current = try #require(try await f.repository.references().first { $0.isCurrent })
    try await f.repository.setReferenceOrganization(current, pinned: true)
    _ = try await GitProcess.run(["remote", "add", "origin", "https://example.invalid/repo.git"], at: root)
    _ = try await GitProcess.run(["branch", "develop"], at: root)
    for (key, value) in [("gitflow.branch.master", current.name), ("gitflow.branch.develop", "develop")] {
        _ = try await GitProcess.run(["config", key, value], at: root)
    }
    let linked = try await f.repository.createWorktree(try await f.repository.previewWorktreeCreation(destination: f.root.appendingPathComponent("Linked"), mode: .detached))
    try await f.write("a.txt", "staged content\n")
    _ = try await GitProcess.run(["add", "a.txt"], at: root)
    try await f.write("local.txt", "untracked content\n")
    let before = try await f.repository.snapshot(countHistory: false)
    await f.store.openInPlace(root)
    #expect(f.store.lastOpenReport?.succeeded == true && !f.store.isBusy)
    #expect(f.store.snapshot?.head == before.head && f.store.changes == before.changes)
    #expect(Set(f.store.workingList.files.map(\.path)) == ["a.txt", "local.txt"])
    #expect(f.store.managedRemotes.first?.fetchURL == "https://example.invalid/repo.git")
    #expect(f.store.organization.pinned.contains(current.fullName))
    #expect(f.store.worktrees.contains { $0.id == linked.id } && f.store.worktrees.count == 2)
    #expect(f.store.flowConfiguration?.production == current.name && f.store.flowConfiguration?.development == "develop")
    #expect(f.store.undoAvailability != nil && f.store.worktreeError == nil && f.store.workflowError == nil)
    #expect(try await f.repository.snapshot(countHistory: false).changes == before.changes)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func failedOpenMetadataKeepsPreviousRepositoryDraftAndSelection() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let workspace = RepositoryWorkspace(library: f.store.library, draftsFile: f.root.appendingPathComponent("open-drafts.json"))
    defer { workspace.shutdown() }
    let root = await f.repository.root
    await workspace.open(root)
    let store = workspace.activeStore, token = store.repositoryToken
    store.commitSubject = "Keep this draft"
    let other = f.root.appendingPathComponent("Broken Metadata")
    _ = try await GitRepository.create(at: other)
    let storage = other.appendingPathComponent(".git/gitpico")
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    try Data("invalid recovery metadata".utf8).write(to: storage.appendingPathComponent("undo.json"))
    await workspace.open(other)
    #expect(store.error != nil && store.lastOpenReport?.succeeded == false)
    #expect(store.repositoryToken == token && store.snapshot?.root == root && workspace.activeTab.root == root)
    #expect(store.commitSubject == "Keep this draft")
    #expect(!workspace.activeTab.isBusy && !workspace.activeTab.showsRepositoryPicker)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RUN_OPEN_BENCHMARK"] == "1", "Explicit isolated repository-open timing only."))
@MainActor func repositoryOpenPerformanceBenchmark() async throws {
    let f = try await PreviewFixture.make(commits: 10000, branches: 150, untracked: 2000); defer { f.clean() }
    let root = await f.repository.root
    for index in 0..<3 { _ = try await GitProcess.run(["remote", "add", "remote-\(index)", "https://example.invalid/repo-\(index).git"], at: root) }
    for index in 0..<8 { _ = try await GitProcess.run(["worktree", "add", "--detach", "--no-checkout", "-q", f.root.appendingPathComponent("tree-\(index)").path, "HEAD"], at: root) }
    let initialHead = try await f.repository.headPosition()
    var records: [[String: Any]] = []
    for _ in 0..<3 {
        let workspace = RepositoryWorkspace(library: f.store.library, draftsFile: f.root.appendingPathComponent("benchmark-drafts.json"))
        let trace = GitCommandTrace(), start = ContinuousClock.now
        await GitCommandTrace.$current.withValue(trace) { await workspace.open(root) }
        let seconds = start.duration(to: .now).secondsValue
        let report = try #require(workspace.activeStore.lastOpenReport)
        #expect(report.succeeded && !workspace.activeTab.isBusy && workspace.activeStore.snapshot?.hasHEAD == true)
        let commands = await trace.samples
        records.append(["wallSeconds": seconds, "open": try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)), "commands": try JSONSerialization.jsonObject(with: JSONEncoder().encode(commands))])
        workspace.activeStore.metadataTask?.cancel(); workspace.shutdown()
    }
    #expect(try await f.repository.headPosition() == initialHead)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
    if let path = ProcessInfo.processInfo.environment["GITPICO_OPEN_BENCHMARK_REPORT"] {
        let report: [String: Any] = ["commits":10000,"branches":150,"untrackedFiles":2000,"worktrees":9,"remotes":3,"headUnchanged":true,"samples":records]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
