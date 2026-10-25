import Foundation
import GitCore
import Testing
@testable import GitPico

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RUN_TREE_REFRESH_BENCHMARK"] == "1", "Explicit isolated checkout, stash and merge refresh benchmark only."))
@MainActor func workingTreeRefreshPerformanceBenchmark() async throws {
    // Compare the former full-refresh policy with the incremental policy on identical fixtures.
    // Timing ends when the mutation task releases busy, before any screen drawing.
    let f = try await PreviewFixture.make(commits: 600, branches: 120, untracked: 0); defer { f.clean() }
    let url = await f.repository.root
    let baseline = ProcessInfo.processInfo.environment["GITPICO_TREE_REFRESH_BASELINE"] == "1"
    let policy: MutationRefresh = baseline ? .full : .workingTree
    try Data("original\n".utf8).write(to: url.appendingPathComponent("tracked.txt"))
    _ = try await GitProcess.run(["add", "."], at: url)
    _ = try await GitProcess.run(["commit", "-m", "Tracked file"], at: url)
    _ = try await GitProcess.run(["branch", "checkout-target"], at: url)
    _ = try await GitProcess.run(["branch", "merge-source"], at: url)
    for index in 0..<2000 { try Data("ignored\n".utf8).write(to: url.appendingPathComponent("ignored-\(index)")) }
    try Data("ignored-*\n".utf8).write(to: url.appendingPathComponent(".git/info/exclude"))
    f.store.snapshot = try await f.repository.snapshot(); await f.store.rebuildWorkingList()
    var samples: [[String:Any]] = []
    for round in 0..<2 {
        for branch in ["checkout-target", "main"] {
            let target = try #require(f.store.snapshot?.references.first { $0.fullName == "refs/heads/" + branch })
            let start = ContinuousClock.now
            f.store.perform("Checkout benchmark", refresh: policy) { try await $0.switchBranch(target) }
            await f.store.operationTask?.value
            let time = start.duration(to: .now)
            #expect(!f.store.isBusy && f.store.error == nil && f.store.snapshot?.branch == branch)
            samples.append(["round":round, "action":"checkout", "seconds":Double(time.components.seconds) + Double(time.components.attoseconds) / 1e18])
        }
        try Data("stash \(round)\n".utf8).write(to: url.appendingPathComponent("tracked.txt"))
        f.store.snapshot = try await f.repository.snapshot(); await f.store.rebuildWorkingList()
        var options = StashSaveOptions(); options.message = "Benchmark"
        let savedOptions = options
        var start = ContinuousClock.now
        f.store.perform("Save benchmark", refresh: policy) { _ = try await $0.saveStash(savedOptions) }
        await f.store.operationTask?.value
        var time = start.duration(to: .now)
        #expect(f.store.error == nil && f.store.changes.isEmpty)
        samples.append(["round":round, "action":"stash-save", "seconds":Double(time.components.seconds) + Double(time.components.attoseconds) / 1e18])
        let stash = try #require(f.store.snapshot?.stashes.first)
        start = .now
        f.store.perform("Pop benchmark", refresh: policy) { try await $0.applyStash(stash, restoreIndex: true, deleteAfter: true) }
        await f.store.operationTask?.value
        time = start.duration(to: .now)
        #expect(f.store.error == nil && f.store.snapshot?.stashes.isEmpty == true && f.store.changes.count == 1)
        samples.append(["round":round, "action":"stash-pop", "seconds":Double(time.components.seconds) + Double(time.components.attoseconds) / 1e18])
        _ = try await GitProcess.run(["restore", "tracked.txt"], at: url)
        _ = try await GitProcess.run(["switch", "merge-source"], at: url)
        _ = try await GitProcess.run(["commit", "--allow-empty", "-m", "Merge source \(round)"], at: url)
        _ = try await GitProcess.run(["switch", "main"], at: url)
        f.store.snapshot = try await f.repository.snapshot(); await f.store.rebuildWorkingList()
        start = .now
        f.store.perform("Merge benchmark", refresh: policy) { try await $0.integrate(.merge, revision: "merge-source") }
        await f.store.operationTask?.value
        time = start.duration(to: .now)
        #expect(f.store.error == nil && f.store.snapshot?.commits.first?.subject == "Merge source \(round)")
        samples.append(["round":round, "action":"merge", "seconds":Double(time.components.seconds) + Double(time.components.attoseconds) / 1e18])
    }
    if let output = ProcessInfo.processInfo.environment["GITPICO_TREE_REFRESH_BENCHMARK_REPORT"] {
        try JSONSerialization.data(withJSONObject: ["policy":baseline ? "full" : "incremental", "commits":600, "branches":122, "ignoredFiles":2000, "samples":samples], options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
