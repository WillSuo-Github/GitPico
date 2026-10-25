import Foundation
import GitCore
import Testing
@testable import GitPico

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RUN_REFRESH_BENCHMARK"] == "1", "Explicit isolated write-refresh benchmark only."))
@MainActor func writeRefreshPerformanceBenchmark() async throws {
    let f = try await PreviewFixture.make(commits: 600, branches: 120, untracked: 2000); defer { f.clean() }
    let url = await f.repository.root
    let file = url.appendingPathComponent("tracked.txt")
    try Data("original\n".utf8).write(to: file)
    _ = try await GitProcess.run(["add", "tracked.txt"], at: url)
    _ = try await GitProcess.run(["commit", "-m", "Tracked file"], at: url)
    f.store.snapshot = try await f.repository.snapshot(); await f.store.rebuildWorkingList()
    var samples: [[String:Any]] = []
    for round in 0..<2 {
        try Data("edit \(round)\n".utf8).write(to: file)
        f.store.snapshot = try await f.repository.snapshot(); await f.store.rebuildWorkingList()
        f.store.setWorkingSelection(["tracked.txt"]); await f.store.detailTask?.value
        for action in ["stage", "unstage", "stage", "commit"] {
            let start = ContinuousClock.now
            if action == "stage" { f.store.stageSelectedFiles() }
            else if action == "unstage" { f.store.unstageSelectedFiles() }
            else { f.store.commitSubject = "Benchmark \(round)"; f.store.commit() }
            await f.store.operationTask?.value
            let duration = start.duration(to: .now)
            #expect(!f.store.isBusy && f.store.error == nil)
            samples.append(["round":round,"action":action,"seconds":Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18])
            await f.store.detailTask?.value
        }
    }
    #expect(try await GitProcess.run(["show", "HEAD:tracked.txt"], at: url).text == "edit 1\n")
    if let output = ProcessInfo.processInfo.environment["GITPICO_REFRESH_BENCHMARK_REPORT"] {
        try JSONSerialization.data(withJSONObject: ["commits":600,"branches":120,"untrackedFiles":2000,"samples":samples], options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
