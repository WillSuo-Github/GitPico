import Foundation
import Testing
@testable import GitCore

@Test func indexDeltaPreservesHistoryAndUpdatesOnlyWorkingState() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let old = try await f.repo.snapshot()
    try f.write("readme.txt", "staged\n")
    try await f.git(["add", "readme.txt"])
    let delta = try await f.repo.incrementalSnapshot(from: old, history: false, browser: true)
    #expect(!delta.headChanged && delta.snapshot.head == old.head)
    #expect(delta.snapshot.commits == old.commits && delta.snapshot.historyCountIsExact)
    #expect(delta.snapshot.changes.first?.isStaged == true)
    #expect(delta.browserFiles?.contains { $0.path == "readme.txt" && $0.isTracked } == true)
}
@Test func commitDeltaRefreshesHeadReferencesBoundedHistoryAndDivergence() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
    try await f.git(["config", "remote.origin.url", f.url.path])
    try await f.git(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
    try await f.git(["branch", "--set-upstream-to=origin/main", "main"])
    let old = try await f.repo.snapshot()
    try await f.git(["commit", "--allow-empty", "-m", "New commit"])
    var options = HistoryOptions(); options.limit = 1
    let delta = try await f.repo.incrementalSnapshot(from: old, history: true, options: options)
    #expect(delta.headChanged && delta.snapshot.head != old.head)
    #expect(delta.snapshot.references.first(where: \.isCurrent)?.hash == delta.snapshot.head.hash)
    #expect(delta.snapshot.commits.first?.subject == "New commit")
    #expect(!delta.snapshot.historyCountIsExact && delta.snapshot.historyCount == 1)
    #expect(delta.snapshot.ahead == 1 && delta.snapshot.behind == 0)
}
@Test func indexDeltaDetectsExternalCheckoutAndHandlesUnbornAndDetachedHeads() async throws {
    let f = try await Fixture.make(initialCommit: false); defer { f.clean() }
    var previous = try await f.repo.snapshot()
    try f.write("new.txt", "new\n"); try await f.git(["add", "new.txt"])
    let unborn = try await f.repo.incrementalSnapshot(from: previous, history: false, browser: true)
    #expect(!unborn.headChanged && !unborn.snapshot.hasHEAD && unborn.snapshot.branch == "main")
    try await f.git(["commit", "-m", "Initial"])
    previous = try await f.repo.incrementalSnapshot(from: unborn.snapshot, history: true).snapshot
    try await f.git(["switch", "-c", "other"])
    let branch = try await f.repo.incrementalSnapshot(from: previous, history: false)
    #expect(branch.headChanged && branch.snapshot.branch == "other")
    try await f.git(["checkout", "--detach", "HEAD"])
    let detached = try await f.repo.incrementalSnapshot(from: branch.snapshot, history: false)
    #expect(detached.headChanged && detached.snapshot.head.branch == "HEAD" && detached.snapshot.branch == "Detached HEAD")
}
@Test func incrementalBrowserRetainsCleanNewFilesAndFlagsAfterIndexWrites() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    var previous = try await f.repo.snapshot()
    try f.write("new.txt", "new\n"); try await f.git(["add", "new.txt"])
    let staged = try await f.repo.incrementalSnapshot(from: previous, history: false, browser: true)
    #expect(staged.browserFiles?.first { $0.path == "new.txt" }?.isTracked == true)
    try await f.git(["restore", "--staged", "new.txt"])
    let unstaged = try await f.repo.incrementalSnapshot(from: staged.snapshot, history: false, browser: true)
    #expect(unstaged.browserFiles?.first { $0.path == "new.txt" }?.isTracked == false)
    try await f.git(["add", "new.txt"]); try await f.git(["commit", "-m", "Add file"])
    previous = try await f.repo.incrementalSnapshot(from: unstaged.snapshot, history: true, browser: true).snapshot
    try await f.git(["update-index", "--assume-unchanged", "readme.txt"])
    let flagged = try await f.repo.incrementalSnapshot(from: previous, history: false, browser: true)
    #expect(flagged.browserFiles?.first { $0.path == "readme.txt" }?.assumeUnchanged == true)
    #expect(flagged.browserFiles?.contains { $0.path == "new.txt" && $0.change == nil } == true)
}
@Test func currentOperationUsesLinkedWorktreeAdministrativeDirectory() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let path = f.url.appendingPathComponent("linked")
    try await f.git(["worktree", "add", "-b", "linked", path.path])
    let linked = try await GitRepository.open(path)
    let gitDir = try await GitProcess.run(["rev-parse", "--absolute-git-dir"], at: path).text.trimmingCharacters(in: .newlines)
    try Data("merge".utf8).write(to: URL(fileURLWithPath: gitDir).appendingPathComponent("MERGE_HEAD"))
    #expect(try await linked.currentOperation() == .merge)
    #expect(try await f.repo.currentOperation() == .none)
}
