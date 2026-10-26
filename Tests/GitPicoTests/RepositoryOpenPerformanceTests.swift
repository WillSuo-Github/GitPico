import AppKit
import Foundation
import GitCore
import Testing
@testable import GitPico

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
