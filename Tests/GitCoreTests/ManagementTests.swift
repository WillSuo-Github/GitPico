import Foundation
import Testing
@testable import GitCore

private func ref(_ fixture: Fixture, _ name: String) async throws -> Reference {
    try #require(try await fixture.repo.references().first { $0.fullName == name })
}

@Test func branchManagementRetainsTrackingAndRejectsStaleReferences() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let base = try await f.repo.headPosition().hash!
    try await f.repo.createBranch("feature/source", at: base, checkout: false)
    #expect(try await f.repo.headPosition().branch == "refs/heads/main")
    try await f.repo.createBranch("feature/tracked", at: base, checkout: true, upstream: "refs/heads/feature/source")
    var branch = try await ref(f, "refs/heads/feature/tracked")
    #expect(branch.upstream == "feature/source")
    try await f.repo.renameBranch(branch, to: "feature/renamed")
    branch = try await ref(f, "refs/heads/feature/renamed")
    #expect(branch.isCurrent && branch.upstream == "feature/source")
    try await f.repo.setUpstream(branch, to: "refs/heads/main")
    #expect(try await ref(f, branch.fullName).upstream == "main")
    branch = try await ref(f, branch.fullName)
    try await f.repo.setUpstream(branch, to: nil)
    #expect(try await ref(f, branch.fullName).upstream.isEmpty)
    try f.write("feature.txt", "new\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Advance branch")
    await #expect(throws: GitFailure.self) { try await f.repo.renameBranch(branch, to: "stale") }
    await #expect(throws: GitFailure.self) { try await f.repo.createBranch("../invalid", at: base, checkout: false) }
}

@Test func branchDeletionIsGuardedAndRecoverable() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("feature/unmerged")
    try f.write("new.txt", "keep history\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Unmerged")
    let branch = try await ref(f, "refs/heads/feature/unmerged")
    await #expect(throws: GitFailure.self) { try await f.repo.deleteBranch(branch, force: true) }
    try await f.repo.switchBranch("main")
    try await f.repo.setReferenceOrganization(branch, archived: true, pinned: true)
    await #expect(throws: GitFailure.self) { try await f.repo.deleteBranch(branch) }
    try await f.repo.deleteBranch(branch, force: true)
    #expect(!(try await f.repo.referenceOrganization().archived.contains(branch.fullName)))
    #expect(!(try await f.repo.referenceOrganization().pinned.contains(branch.fullName)))
    #expect(!(try await f.repo.references().contains { $0.fullName == branch.fullName }))
    let backup = try #require(try await f.repo.referenceBackups().first)
    let reopened = try await GitRepository.open(f.url)
    try await reopened.restoreReferenceBackup(backup, name: "recovered/unmerged")
    #expect(try await reopened.references().first { $0.name == "recovered/unmerged" }?.hash == branch.hash)
    await #expect(throws: GitFailure.self) { try await reopened.restoreReferenceBackup(backup, name: "recovered/unmerged") }
}

@Test func branchManagementProtectsOtherWorktreesAndSharesOrganization() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("linked", at: "HEAD", checkout: false)
    let branch = try await ref(f, "refs/heads/linked")
    let linked = f.url.appendingPathComponent("Linked")
    try await f.git(["worktree", "add", linked.path, "linked"])
    await #expect(throws: GitFailure.self) { try await f.repo.renameBranch(branch, to: "moved") }
    await #expect(throws: GitFailure.self) { try await f.repo.deleteBranch(branch, force: true) }
    try await f.repo.setReferenceOrganization(branch, archived: true, pinned: true)
    let repo = try await GitRepository.open(linked)
    let organization = try await repo.referenceOrganization()
    #expect(organization.archived.contains(branch.fullName) && organization.pinned.contains(branch.fullName))
    try await repo.setReferenceOrganization(branch, archived: false)
    #expect(!(try await f.repo.referenceOrganization().archived.contains(branch.fullName)))
}

@Test func tagCreationRenameAndRecoveryPreserveAnnotatedObject() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createTag("v1", at: "HEAD")
    try await f.repo.createTag("release/2", at: "HEAD", message: "Full annotation", annotated: true)
    let tag = try await ref(f, "refs/tags/release/2")
    #expect(try await f.git(["cat-file", "-t", tag.hash]).text.trimmingCharacters(in: .newlines) == "tag")
    try await f.repo.renameTag(tag, to: "release/renamed")
    let renamed = try await ref(f, "refs/tags/release/renamed")
    #expect(renamed.hash == tag.hash)
    await #expect(throws: GitFailure.self) { try await f.repo.renameTag(renamed, to: "v1") }
    #expect(try await ref(f, renamed.fullName).hash == tag.hash)
    try await f.repo.deleteTag(renamed)
    let backup = try #require(try await f.repo.referenceBackups().first { $0.isTag })
    try await f.repo.restoreReferenceBackup(backup, name: "restored")
    #expect(try await ref(f, "refs/tags/restored").hash == tag.hash)
    await #expect(throws: GitFailure.self) { try await f.repo.deleteTag(renamed) }
}

private func bareRemote(_ f: Fixture, name: String = "Remote.git") async throws -> URL {
    let url = f.url.appendingPathComponent(name)
    try await f.git(["init", "--bare", "--initial-branch=main", url.path])
    return url
}

@Test func remoteCRUDPreservesURLsRefspecsAndTracking() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let server = try await bareRemote(f)
    try await f.repo.addRemote(name: "origin", fetchURLs: [server.path], pushURLs: [server.path, server.path + "/"])
    var remote = try #require(try await f.repo.remoteConfigurations().first)
    #expect(remote.pushURLs.count == 2 && remote.refspecs.count == 1)
    try await f.git(["config", "remote.origin.prune", "true"])
    try await f.repo.editRemote(remote, fetchURLs: [server.path, "https://example.invalid/repo.git"], pushURLs: [])
    remote = try #require(try await f.repo.remoteConfigurations().first)
    #expect(remote.fetchURLs.count == 2 && remote.pushURLs.isEmpty)
    #expect(try await f.git(["config", "remote.origin.prune"]).text.trimmingCharacters(in: .newlines) == "true")
    try await f.repo.editRemote(remote, fetchURLs: [server.path], pushURLs: [])
    remote = try #require(try await f.repo.remoteConfigurations().first)
    try await f.repo.renameRemote(remote, to: "upstream")
    await #expect(throws: GitFailure.self) { try await f.repo.editRemote(remote, fetchURLs: ["changed"], pushURLs: []) }
    remote = try #require(try await f.repo.remoteConfigurations().first)
    try await f.git(["config", "branch.main.remote", "upstream"]); try await f.git(["config", "branch.main.merge", "refs/heads/main"])
    try await f.repo.removeRemote(remote)
    #expect(try await f.repo.remoteConfigurations().isEmpty)
    let removed = try #require(try await f.repo.removedRemotes().first)
    try await f.repo.restoreRemote(removed)
    #expect(try await f.repo.remoteConfigurations().first?.name == "upstream")
    #expect(try await f.git(["config", "branch.main.remote"]).text.trimmingCharacters(in: .newlines) == "upstream")
    #expect(try await f.git(["config", "remote.upstream.prune"]).text.trimmingCharacters(in: .newlines) == "true")
}

@Test func remoteConfigLockAndValidationDoNotOverwriteData() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let config = f.url.appendingPathComponent(".git/config"), lock = f.url.appendingPathComponent(".git/config.lock")
    let original = try Data(contentsOf: config)
    try Data("external lock".utf8).write(to: lock)
    await #expect(throws: GitFailure.self) { try await f.repo.addRemote(name: "origin", fetchURLs: ["/tmp/repo.git"]) }
    #expect(try Data(contentsOf: config) == original && Data(contentsOf: lock) == Data("external lock".utf8))
    try FileManager.default.removeItem(at: lock)
    await #expect(throws: GitFailure.self) { try await f.repo.addRemote(name: "--bad", fetchURLs: ["url"]) }
    await #expect(throws: GitFailure.self) { try await f.repo.addRemote(name: "valid", fetchURLs: ["-upload-pack=bad"]) }
    #expect(try Data(contentsOf: config) == original)
}

@Test func publishBranchesTagsAndDeleteWithLeaseUsingLocalServer() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let server = try await bareRemote(f)
    try await f.repo.addRemote(name: "origin", fetchURLs: [server.path])
    let remote = try #require(try await f.repo.remoteConfigurations().first)
    let main = try await ref(f, "refs/heads/main")
    let preview = try await f.repo.pushPreview(remote: remote, source: main, destination: "refs/heads/review", setUpstream: true)
    #expect(preview.remoteHash == nil)
    try await f.repo.executePush(preview)
    #expect(try await ref(f, main.fullName).upstream == "origin/review")
    let remoteHash = try await GitProcess.run(["rev-parse", "refs/heads/review"], at: server).text.trimmingCharacters(in: .newlines)
    #expect(remoteHash == main.hash)
    try await f.repo.createTag("v1", at: "HEAD", message: "Release", annotated: true)
    let tag = try await ref(f, "refs/tags/v1")
    try await f.repo.executePush(try await f.repo.pushPreview(remote: remote, source: tag, destination: tag.fullName))
    #expect(try await GitProcess.run(["rev-parse", tag.fullName], at: server).text.trimmingCharacters(in: .newlines) == tag.hash)
    let deletion = try await f.repo.pushPreview(remote: remote, source: nil, destination: "refs/heads/review")
    try await f.repo.executePush(deletion)
    #expect(try await GitProcess.run(["show-ref", "--verify", "--quiet", "refs/heads/review"], at: server, allowed: [0, 1]).status == 1)
}

@Test func pushLeaseRejectsRemoteChangesAfterPreview() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let server = try await bareRemote(f)
    try await f.repo.addRemote(name: "origin", fetchURLs: [server.path])
    let remote = try #require(try await f.repo.remoteConfigurations().first)
    let main = try await ref(f, "refs/heads/main")
    try await f.repo.executePush(try await f.repo.pushPreview(remote: remote, source: main, destination: "refs/heads/main"))
    let preview = try await f.repo.pushPreview(remote: remote, source: main, destination: "refs/heads/main", forceWithLease: true)
    try await f.git(["commit", "--allow-empty", "-m", "External change"])
    let next = try await f.repo.headPosition().hash!
    try await f.git(["push", "origin", "main"])
    try await f.git(["update-ref", "refs/heads/main", main.hash, next])
    await #expect(throws: GitFailure.self) { try await f.repo.executePush(preview) }
    #expect(try await GitProcess.run(["rev-parse", "refs/heads/main"], at: server).text.trimmingCharacters(in: .newlines) == next)
}
