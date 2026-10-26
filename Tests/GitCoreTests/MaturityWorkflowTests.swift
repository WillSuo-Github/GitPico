import Foundation
import Testing
@testable import GitCore

@Test func allReferenceFileHistoryIncludesUnmergedBranchesAcrossEarlierNames() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["switch", "-c", "side"])
    try f.write("readme.txt", "side-only content\n")
    try await f.git(["add", "readme.txt"]); try await f.git(["commit", "-m", "Side edit"])
    try await f.git(["switch", "main"])
    try await f.git(["mv", "readme.txt", "renamed.txt"]); try await f.git(["commit", "-m", "Rename on main"])
    let history = try await f.repo.fileHistoryAcrossReferences(path: "renamed.txt")
    #expect(history.revisions.contains { $0.commit.subject == "Side edit" && $0.path == "readme.txt" })
    #expect(history.revisions.contains { $0.commit.subject == "Rename on main" })
    #expect(Set(history.revisions.map(\.id)).count == history.revisions.count)
    #expect(try await f.repo.headPosition().branch == "refs/heads/main")
}

@Test func binaryComparisonReadsExactIndexWorkingAndRenamedRevisionBytes() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let original = Data([0, 1, 2, 3]), staged = Data([0, 4, 5]), working = Data([0, 9, 8, 7, 6])
    let path = "literal[1].bin"
    try original.write(to: f.url.appendingPathComponent(path))
    try await f.git(["add", "--", path]); try await f.git(["commit", "-m", "Binary baseline"])
    let baseline = try await f.repo.headPosition()
    try staged.write(to: f.url.appendingPathComponent(path)); try await f.git(["add", "--", path])
    try working.write(to: f.url.appendingPathComponent(path))
    let comparison = try await f.repo.binaryComparison(path: path, left: .index, right: .workingCopy)
    #expect(comparison.left == staged && comparison.right == working)
    let head = try await f.repo.binaryComparison(path: path, left: .revision("HEAD"), right: .index)
    #expect(head.left == original && head.right == staged)
    try await f.git(["restore", "--staged", "--worktree", "--", path])
    try await f.git(["mv", "--", path, "renamed.bin"]); try await f.git(["commit", "-m", "Rename binary"])
    let renamed = try await f.repo.binaryComparison(path: "renamed.bin", left: .revision(try #require(baseline.hash)), right: .revision("HEAD"))
    #expect(renamed.left == original && renamed.right == original)
    let absent = try await f.repo.binaryComparison(path: "missing.bin", left: .index, right: .workingCopy)
    #expect(absent.left == nil && absent.right == nil)
    try FileManager.default.createSymbolicLink(atPath: f.url.appendingPathComponent("linked.bin").path, withDestinationPath: "/etc/passwd")
    await #expect(throws: GitFailure.self) { try await f.repo.binaryComparison(path: "linked.bin", left: .empty, right: .workingCopy) }
}

@Test func missingUpstreamDoesNotPreventSnapshotOrIncrementalRefresh() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["remote", "add", "origin", "/nonexistent/GitPico-acceptance.git"])
    try await f.git(["config", "branch.main.remote", "origin"])
    try await f.git(["config", "branch.main.merge", "refs/heads/missing"])
    let snapshot = try await f.repo.snapshot()
    #expect(snapshot.hasHEAD && !snapshot.commits.isEmpty)
    #expect(snapshot.unresolvedUpstream == "origin/missing")
    let refreshed = try await f.repo.incrementalSnapshot(from: snapshot, history: true)
    #expect(refreshed.snapshot.unresolvedUpstream == "origin/missing")
    #expect(refreshed.snapshot.head == snapshot.head)
    await #expect(throws: GitFailure.self) { try await f.repo.pull(policy: .merge, expectedHead: snapshot.head, expectedUpstream: "origin/changed") }
    #expect(try await f.repo.headPosition() == snapshot.head)
}

@Test func pullPoliciesIntegrateDivergenceWithoutChangingUnrelatedFiles() async throws {
    for policy in PullPolicy.allCases {
        let f = try await Fixture.make(); defer { f.clean() }
        let origin = f.url.appendingPathComponent(".git/pull-origin.git"), peer = f.url.appendingPathComponent(".git/pull-peer")
        try await f.git(["init", "--bare", origin.path])
        try await f.git(["remote", "add", "origin", origin.path])
        try await f.git(["push", "-u", "origin", "main"])
        try await f.git(["clone", "--branch", "main", origin.path, peer.path])
        for (key, value) in [("user.name", "Peer"), ("user.email", "peer@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = try await GitProcess.run(["config", key, value], at: peer)
        }
        try "remote\n".write(to: peer.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
        for args in [["add", "remote.txt"], ["commit", "-m", "Remote change"], ["push", "origin", "main"]] { _ = try await GitProcess.run(args, at: peer) }
        try await f.git(["commit", "--allow-empty", "-m", "Local change"])
        let before = try await f.repo.headPosition()
        if policy == .fastForwardOnly {
            await #expect(throws: GitFailure.self) { try await f.repo.pull(policy: policy, expectedHead: before) }
            #expect(try await f.repo.headPosition() == before)
        } else {
            try await f.repo.pull(policy: policy, expectedHead: before)
            let state = try await f.repo.snapshot()
            #expect(state.operation == .none && state.changes.isEmpty && state.behind == 0)
            #expect(try String(contentsOf: f.url.appendingPathComponent("remote.txt"), encoding: .utf8) == "remote\n")
            #expect(state.commits[0].parents.count == (policy == .merge ? 2 : 1))
            if policy == .merge {
                let merge = state.commits[0]
                let first = try await f.repo.compareRevisions(left: merge.parents[0], right: merge.hash)
                let second = try await f.repo.compareRevisions(left: merge.parents[1], right: merge.hash)
                #expect(first.files.contains { $0.path == "remote.txt" })
                #expect(second.files.isEmpty)
            }
            #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\n")
        }
    }
}
