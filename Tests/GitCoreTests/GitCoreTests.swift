import Foundation
import Testing
@testable import GitCore

struct Fixture: Sendable {
    let url: URL
    let repo: GitRepository
    static func make(initialCommit: Bool = true) async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await GitProcess.run(["init", "-b", "main"], at: url)
        for (key, value) in [("user.name", "Test Author"), ("user.email", "test@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = try await GitProcess.run(["config", key, value], at: url)
        }
        let fixture = Fixture(url: url, repo: try await GitRepository.open(url))
        if initialCommit {
            try fixture.write("readme.txt", "original\n")
            _ = try await fixture.git(["add", "--", "readme.txt"])
            _ = try await fixture.git(["commit", "-m", "Initial | commit"])
        }
        return fixture
    }
    func clean() { try? FileManager.default.removeItem(at: url) }
    func write(_ path: String, _ text: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
    @discardableResult func git(_ args: [String], allowed: Set<Int32> = [0]) async throws -> GitOutput {
        try await GitProcess.run(args, at: url, allowed: allowed)
    }
}

@Test func porcelainPreservesUnusualNamesAndRenamePairs() {
    let data = Data(" M folder/a b.txt\0?? 中文\nname.txt\0R  new.txt\0old.txt\0MM both.txt\0".utf8)
    let changes = GitParser.status(data)
    #expect(changes.count == 4)
    #expect(changes[0].path == "folder/a b.txt")
    #expect(changes[1].path == "中文\nname.txt")
    #expect(changes[2].originalPath == "old.txt")
    #expect(changes[2].isStaged)
    #expect(changes[3].isStaged && changes[3].isUnstaged)
}

@Test func unbornRepositoryAndUnstagePreserveLaterEdits() async throws {
    let f = try await Fixture.make(initialCommit: false); defer { f.clean() }
    #expect(try await f.repo.snapshot().commits.isEmpty)
    try f.write("first.txt", "staged version\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try f.write("first.txt", "later edits\n")
    let staged = try await f.repo.snapshot().changes
    #expect(staged[0].isStaged && staged[0].isUnstaged)
    try await f.repo.unstage(staged)
    #expect(try String(contentsOf: f.url.appendingPathComponent("first.txt"), encoding: .utf8) == "later edits\n")
    #expect(try await f.repo.snapshot().changes[0].isUntracked)
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "The first commit\n\nWith a body")
    let snapshot = try await f.repo.snapshot()
    #expect(snapshot.hasHEAD && snapshot.commits.count == 1 && snapshot.changes.isEmpty)
    let detail = try await f.repo.detail(snapshot.commits[0])
    #expect(detail.message == "The first commit\n\nWith a body")
    #expect(detail.files.map(\.path) == ["first.txt"])
}

@Test func partialStagingAndLiteralPathspecs() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "first edit\n")
    let change = try #require(try await f.repo.snapshot().changes.first)
    try await f.repo.stage([change])
    try f.write("readme.txt", "second edit\n")
    let both = try #require(try await f.repo.snapshot().changes.first)
    #expect(both.isStaged && both.isUnstaged)
    #expect(try await f.repo.diff(both, staged: true).contains("+first edit"))
    #expect(try await f.repo.diff(both, staged: false).contains("+second edit"))
    try await f.repo.unstage([both])
    #expect(!(try await f.repo.snapshot().changes[0].isStaged))
    for name in [":(glob)*.txt", "a b.txt", "中文\nname.txt", "--option.txt"] { try f.write(name, "literal\n") }
    let target = try #require(try await f.repo.snapshot().changes.first { $0.path == ":(glob)*.txt" })
    try await f.repo.stage([target])
    let staged = try await f.repo.snapshot().changes.filter(\.isStaged)
    #expect(staged.map(\.path) == [":(glob)*.txt"])
    #expect(try await f.repo.diff(target, staged: false).contains("literal"))
}

@Test func stageRenameUnstageAndDeletion() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    _ = try await f.git(["mv", "--", "readme.txt", "renamed file.txt"])
    var changes = try await f.repo.snapshot().changes
    #expect(changes.count == 1 && changes[0].originalPath == "readme.txt")
    try await f.repo.unstage(changes)
    changes = try await f.repo.snapshot().changes
    #expect(changes.contains { $0.path == "readme.txt" && $0.worktree == "D" })
    try await f.repo.stage(changes)
    try await f.repo.commit(message: "Rename")
    var snapshot = try await f.repo.snapshot()
    let detail = try await f.repo.detail(snapshot.commits[0])
    #expect(detail.files.count == 1 && detail.files[0].path == "renamed file.txt")
    try FileManager.default.removeItem(at: f.url.appendingPathComponent("renamed file.txt"))
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Delete")
    snapshot = try await f.repo.snapshot()
    #expect(snapshot.changes.isEmpty)
    #expect(try await f.repo.detail(snapshot.commits[0]).files[0].status == "D")
}

@Test func branchesTagsScopeAndMergeGraph() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("feature/test")
    try f.write("feature.txt", "feature\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Feature")
    try await f.repo.switchBranch("main")
    try f.write("main.txt", "main\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Main")
    _ = try await f.git(["merge", "--no-ff", "feature/test", "-m", "Merge feature"])
    _ = try await f.git(["tag", "v0.1.0"])
    let snapshot = try await f.repo.snapshot()
    #expect(snapshot.commits.count == 4)
    #expect(snapshot.references.contains { $0.name == "main" && $0.isCurrent })
    #expect(snapshot.references.contains { $0.name == "v0.1.0" && $0.isTag })
    #expect(snapshot.commits[0].parents.count == 2)
    #expect(try await f.repo.detail(snapshot.commits[0]).files.map(\.path) == ["feature.txt"])
    let scoped = try await f.repo.snapshot(ref: "refs/heads/feature/test")
    #expect(scoped.commits.count == 2)
    let graph = CommitGraph.layout(snapshot.commits)
    #expect(graph[snapshot.commits[0].hash]?.incoming.isEmpty == true)
    #expect(graph[snapshot.commits[0].hash]?.outgoing.count == 2)
    #expect((graph.values.map(\.laneCount).max() ?? 0) >= 2)
}

@Test func checkoutFailurePreservesDirtyWorktree() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("changed")
    try f.write("readme.txt", "branch version\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Change")
    try await f.repo.switchBranch("main")
    try f.write("readme.txt", "precious edits\n")
    await #expect(throws: GitFailure.self) { try await f.repo.switchBranch("changed") }
    #expect(try await f.repo.snapshot().branch == "main")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "precious edits\n")
    await #expect(throws: GitFailure.self) { try await f.repo.createBranch("--bad-name") }
}

@Test func conflictDetectionAndCommitGuard() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("other")
    try f.write("readme.txt", "other\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Other")
    try await f.repo.switchBranch("main")
    try f.write("readme.txt", "main\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Main")
    _ = try await f.git(["merge", "other", "--no-edit"], allowed: [1])
    #expect(try await f.repo.snapshot().changes.contains(where: \.isConflicted))
    await #expect(throws: GitFailure.self) { try await f.repo.commit(message: "Must not commit conflicts") }
}

@Test func stashRoundTripKeepsStashAndUntrackedFiles() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "work in progress\n")
    try f.write("untracked.txt", "new\n")
    try await f.repo.saveStash(message: "Paused work")
    var snapshot = try await f.repo.snapshot()
    #expect(snapshot.changes.isEmpty && snapshot.stashes.count == 1)
    #expect(snapshot.commits.count == 1)
    let stash = try #require(snapshot.stashes.first)
    #expect(try await f.repo.stashDiff(stash).contains("work in progress"))
    try await f.repo.applyStash(stash)
    snapshot = try await f.repo.snapshot()
    #expect(snapshot.stashes.count == 1 && snapshot.changes.count == 2)
}

@Test func linkedWorktreeAndNestedFolderResolveRoot() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try FileManager.default.createDirectory(at: f.url.appendingPathComponent("nested/deep"), withIntermediateDirectories: true)
    let nested = try await GitRepository.open(f.url.appendingPathComponent("nested/deep"))
    #expect(await nested.root == f.url.resolvingSymlinksInPath())
    let worktreeURL = f.url.appendingPathComponent("linked")
    _ = try await f.git(["worktree", "add", "-b", "linked", worktreeURL.path])
    let worktree = try await GitRepository.open(worktreeURL)
    #expect(try await worktree.snapshot().branch == "linked")
}

@Test func localRemoteFetchPullAndPush() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let remote = f.url.appendingPathComponent("remote.git")
    _ = try await f.git(["init", "--bare", remote.path])
    _ = try await f.git(["remote", "add", "origin", remote.path])
    #expect(try await f.repo.configuration().remotes.first?.fetchURL == remote.path)
    _ = try await f.git(["push", "-u", "origin", "main"])
    try await f.repo.sync(.fetch)
    try await f.repo.sync(.pull)
    try f.write("readme.txt", "next\n")
    let changes = try await f.repo.snapshot().changes.filter { $0.path == "readme.txt" }
    try await f.repo.stage(changes)
    try await f.repo.commit(message: "Next")
    #expect(try await f.repo.snapshot().ahead == 1)
    try await f.repo.sync(.push)
    #expect(try await f.repo.snapshot().ahead == 0)
}

@Test func diffNumbersAndPreviewLimit() {
    let d = DiffDocument("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -2,2 +2,2 @@\n same\n-old\n+new\n")
    #expect(d.lines[4].oldNumber == 2 && d.lines[4].newNumber == 2)
    #expect(d.lines[5].oldNumber == 3 && d.lines[5].newNumber == nil)
    #expect(d.lines[6].newNumber == 3 && d.lines[6].oldNumber == nil)
    #expect(DiffDocument("a\nb\nc", limit: 2).isTruncated)
    let patch = PatchDocument("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1,2 @@\n same\n+++new content\n")
    #expect(patch.additions == 1)
    #expect(patch.preview(limit: 2).first?.isTruncated == true)
}

@Test func errorsAndEmptyCommitAreReported() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    await #expect(throws: GitFailure.self) { try await f.repo.commit(message: "") }
    await #expect(throws: GitFailure.self) { try await f.repo.commit(message: "No staged files") }
    let plain = f.url.appendingPathComponent("plain")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    // A subdirectory belongs to the parent repository; an unrelated directory does not.
    let unrelated = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-plain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: unrelated) }
    await #expect(throws: GitFailure.self) { _ = try await GitRepository.open(unrelated) }
}
