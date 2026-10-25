import Foundation
import Testing
@testable import GitCore

@Test func renamingNewestStashChangesOnlyMetadataAndRemainsApplicable() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "changed\n"); try await f.repo.saveStash(message: "Original")
    let old = try #require(try await f.repo.stashList().first)
    let renamed = try await f.repo.renameStash(old, message: "Renamed newest")
    let oldCommit = try await f.repo.commit(at: old.hash), newCommit = try await f.repo.commit(at: renamed.hash)
    #expect(try await f.repo.stashList().count == 1)
    #expect(newCommit.parents == oldCommit.parents && newCommit.subject == "Renamed newest")
    #expect(try await f.git(["rev-parse", old.hash + "^{tree}"]).text == f.git(["rev-parse", renamed.hash + "^{tree}"]).text)
    try await f.repo.applyStash(renamed, restoreIndex: true, deleteAfter: false)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "changed\n")
}

@Test func repeatedSnapshotsPreserveWorkingAndIndexContent() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "staged\n"); try await f.repo.stage(try await f.repo.snapshot().changes)
    try f.write("readme.txt", "working\n")
    var options = StashSaveOptions(); options.snapshot = true; options.message = "Same snapshot"
    _ = try await f.repo.saveStash(options); _ = try await f.repo.saveStash(options)
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "working\n")
}

@Test func stashFileApplyChecksAllPatchesBeforeChangingAnyFiles() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "stash change\n"); try f.write("untracked.txt", "stash file\n")
    try await f.repo.saveStash(message: "Collision")
    let stash = try #require(try await f.repo.stashList().first)
    try f.write("untracked.txt", "keep current\n")
    await #expect(throws: GitFailure.self) { try await f.repo.applyStashFiles(stash, paths: ["readme.txt", "untracked.txt"]) }
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("untracked.txt"), encoding: .utf8) == "keep current\n")
    #expect(try await f.repo.stashList().count == 1)
}

@Test func fetchOptionsPruneOnlyTrackingRefsAndFetchTags() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let server = f.url.appendingPathComponent("Server.git")
    try await f.git(["init", "--bare", "--initial-branch=main", server.path])
    try await f.repo.addRemote(name: "origin", fetchURLs: [server.path])
    let remote = try #require(try await f.repo.remoteConfigurations().first)
    try await f.git(["push", "origin", "main:main", "main:temporary"])
    try await f.repo.createTag("v1", at: "HEAD")
    try await f.git(["push", "origin", "refs/tags/v1"])
    try await f.repo.deleteTag(try #require(try await f.repo.references().first { $0.name == "v1" }))
    try await f.repo.fetchRemote(remote, tags: true)
    #expect(try await f.repo.references().contains { $0.fullName == "refs/tags/v1" })
    try await GitProcess.run(["update-ref", "-d", "refs/heads/temporary"], at: server)
    try await f.repo.fetchRemote(remote, prune: true)
    #expect(!(try await f.repo.references().contains { $0.fullName == "refs/remotes/origin/temporary" }))
    #expect(try await f.repo.references().contains { $0.fullName == "refs/heads/main" })
}

@Test func publishSelectsOnlyOneOfMultiplePushURLs() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let first = f.url.appendingPathComponent("First.git"), second = f.url.appendingPathComponent("Second.git")
    for server in [first, second] { try await f.git(["init", "--bare", "--initial-branch=main", server.path]) }
    try await f.repo.addRemote(name: "origin", fetchURLs: [first.path], pushURLs: [first.path, second.path])
    let remote = try #require(try await f.repo.remoteConfigurations().first)
    let source = try #require(try await f.repo.references().first { $0.isCurrent })
    let preview = try await f.repo.pushPreview(remote: remote, source: source, destination: "refs/heads/main", pushURL: second.path)
    try await f.repo.executePush(preview)
    #expect(try await GitProcess.run(["show-ref", "--verify", "--quiet", "refs/heads/main"], at: first, allowed: [0, 1]).status == 1)
    #expect(try await GitProcess.run(["rev-parse", "refs/heads/main"], at: second).text.trimmingCharacters(in: .newlines) == source.hash)
    await #expect(throws: GitFailure.self) { try await f.repo.pushPreview(remote: remote, source: source, destination: "refs/heads/main", setUpstream: true, pushURL: second.path) }
}
