import Foundation
import Testing
@testable import GitCore

private func remoteCheckoutFixture(name: String = "feature/远端", remote: String = "origin") async throws -> (Fixture, Reference) {
    let f = try await Fixture.make()
    try await f.git(["remote", "add", remote, f.url.path])
    try await f.git(["update-ref", "refs/remotes/" + remote + "/" + name, "HEAD"])
    return (f, try #require(try await f.repo.references().first { $0.fullName == "refs/remotes/" + remote + "/" + name }))
}

private func remoteCheckoutTarget(_ f: Fixture, _ remote: Reference) async throws -> RemoteBranchCheckoutTarget {
    try await .resolve(remote, references: f.repo.references(), remotes: f.repo.remoteConfigurations().map(\.name))
}

@Test func remoteCheckoutCreatesLocalBranchAtRemoteTipWithUpstream() async throws {
    let (f, remote) = try await remoteCheckoutFixture(); defer { f.clean() }
    try await f.git(["commit", "--allow-empty", "-m", "Local main ahead"])
    let target = try await remoteCheckoutTarget(f, remote)
    #expect(target == .create("feature/远端"))
    try await f.repo.switchRemoteBranch(remote, target: target)
    let head = try await f.repo.headPosition()
    #expect(head.branch == "refs/heads/feature/远端" && head.hash == remote.hash)
    #expect(try await f.git(["rev-parse", "--symbolic-full-name", "@{upstream}"]).text.trimmingCharacters(in: .newlines) == remote.fullName)
    try await f.repo.switchBranch("main")
    guard case .existing(let local) = try await remoteCheckoutTarget(f, remote) else { Issue.record("Expected qualified upstream to resolve"); return }
    #expect(local.name == "feature/远端")
}

@Test func remoteCheckoutReusesRenamedTrackingBranchWithoutResettingItsCommits() async throws {
    let (f, remote) = try await remoteCheckoutFixture(); defer { f.clean() }
    try await f.repo.createBranch("my-topic", at: remote.hash, checkout: true, upstream: remote.fullName)
    try await f.git(["commit", "--allow-empty", "-m", "Local work"])
    let localTip = try await f.repo.headPosition().hash
    try await f.repo.switchBranch("main")
    let target = try await remoteCheckoutTarget(f, remote)
    guard case .existing(let local) = target else { Issue.record("Expected existing tracking branch"); return }
    #expect(local.name == "my-topic")
    try await f.repo.switchRemoteBranch(remote, target: target)
    #expect(try await f.repo.headPosition().hash == localTip)
    #expect(try await f.repo.headPosition().branch == local.fullName)
}

@Test func remoteCheckoutRequiresChoiceForCollisionsAndAmbiguousTracking() async throws {
    let (f, remote) = try await remoteCheckoutFixture(); defer { f.clean() }
    try await f.git(["branch", "feature/远端"])
    #expect(try await remoteCheckoutTarget(f, remote) == .chooseName)
    await #expect(throws: GitFailure.self) { try await f.repo.switchRemoteBranch(remote, target: .create("feature/远端")) }
    try await f.git(["branch", "-D", "feature/远端"])
    for name in ["first", "second"] { try await f.repo.createBranch(name, at: remote.hash, checkout: false, upstream: remote.fullName) }
    #expect(try await remoteCheckoutTarget(f, remote) == .chooseName)
    try await f.repo.createBranch("feature/远端", at: remote.hash, checkout: false, upstream: remote.fullName)
    guard case .existing(let local) = try await remoteCheckoutTarget(f, remote) else { Issue.record("Expected same-name tracking branch"); return }
    #expect(local.name == "feature/远端")
    #expect(try await f.repo.headPosition().branch == "refs/heads/main")
}

@Test func remoteCheckoutRejectsMovedRemoteAndChangedLocalPlan() async throws {
    let (f, remote) = try await remoteCheckoutFixture(); defer { f.clean() }
    let target = try await remoteCheckoutTarget(f, remote)
    try await f.git(["commit", "--allow-empty", "-m", "New remote tip"])
    try await f.git(["update-ref", remote.fullName, "HEAD"])
    await #expect(throws: GitFailure.self) { try await f.repo.switchRemoteBranch(remote, target: target) }
    try await f.git(["update-ref", remote.fullName, remote.hash])
    try await f.git(["branch", "feature/远端"])
    await #expect(throws: GitFailure.self) { try await f.repo.switchRemoteBranch(remote, target: target) }
    #expect(try await f.repo.headPosition().branch == "refs/heads/main")
}

@Test func remoteCheckoutFailedSwitchDoesNotLeaveNewBranchOrLoseFiles() async throws {
    let (f, remote) = try await remoteCheckoutFixture(); defer { f.clean() }
    try f.write("readme.txt", "different main\n")
    try await f.git(["commit", "-am", "Change main"])
    try f.write("readme.txt", "uncommitted work\n")
    let target = try await remoteCheckoutTarget(f, remote)
    await #expect(throws: GitFailure.self) { try await f.repo.switchRemoteBranch(remote, target: target) }
    #expect(try await f.repo.references().contains { $0.fullName == "refs/heads/feature/远端" } == false)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "uncommitted work\n")
    #expect(try await f.repo.headPosition().branch == "refs/heads/main")
}

@Test func remoteCheckoutProtectsOtherWorktreesAndInProgressOperations() async throws {
    let (f, remote) = try await remoteCheckoutFixture(); defer { f.clean() }
    try await f.repo.createBranch("topic", at: remote.hash, checkout: false, upstream: remote.fullName)
    let target = try await remoteCheckoutTarget(f, remote)
    try await f.git(["worktree", "add", f.url.appendingPathComponent("linked").path, "topic"])
    await #expect(throws: GitFailure.self) { try await f.repo.switchRemoteBranch(remote, target: target) }
    try f.write(".git/MERGE_HEAD", remote.hash + "\n")
    await #expect(throws: GitFailure.self) { try await f.repo.switchRemoteBranch(remote, target: target) }
    #expect(try await f.repo.headPosition().branch == "refs/heads/main")
}

@Test func remoteCheckoutHandlesSlashRemoteNamesAndRejectsSymbolicHead() async throws {
    let (f, remote) = try await remoteCheckoutFixture(name: "feature/topic", remote: "team/origin"); defer { f.clean() }
    #expect(try await RemoteBranchCheckoutTarget.resolve(remote, references: f.repo.references(), remotes: ["team", "team/origin"]) == .create("feature/topic"))
    try await f.git(["symbolic-ref", "refs/remotes/team/origin/HEAD", remote.fullName])
    let head = try #require(try await f.repo.references().first { $0.fullName == "refs/remotes/team/origin/HEAD" })
    await #expect(throws: GitFailure.self) { _ = try await remoteCheckoutTarget(f, head) }
}

@Test func remoteCheckoutUsesQualifiedRemoteEvenWhenShortNameIsAmbiguous() async throws {
    let (f, remote) = try await remoteCheckoutFixture(); defer { f.clean() }
    try await f.git(["commit", "--allow-empty", "-m", "Unrelated tip"])
    try await f.git(["branch", remote.name])
    let target = try await remoteCheckoutTarget(f, remote)
    try await f.repo.switchRemoteBranch(remote, target: target)
    #expect(try await f.repo.headPosition().hash == remote.hash)
    #expect(try await f.git(["rev-parse", "--symbolic-full-name", "@{upstream}"]).text.trimmingCharacters(in: .newlines) == remote.fullName)
    try await f.repo.switchBranch("main")
    guard case .existing(let local) = try await remoteCheckoutTarget(f, remote) else { Issue.record("Expected qualified upstream to resolve"); return }
    #expect(local.name == "feature/远端")
}

@Test func checkoutReferenceRejectsMovedTargetAndPreservesHead() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["branch", "topic"])
    let ref = try #require(try await f.repo.references().first { $0.name == "topic" })
    try await f.git(["commit", "--allow-empty", "-m", "New tip"])
    try await f.git(["branch", "-f", "topic", "HEAD"])
    let head = try await f.repo.headPosition()
    await #expect(throws: GitFailure.self) { try await f.repo.switchBranch(ref) }
    #expect(try await f.repo.headPosition() == head)
}
@Test func checkoutReferencePreservesLocalChangesAndRejectsOperationInProgress() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["branch", "topic"])
    let ref = try #require(try await f.repo.references().first { $0.name == "topic" })
    try f.write("readme.txt", "Local edits\n")
    try await f.repo.switchBranch(ref)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "Local edits\n")
    let main = try #require(try await f.repo.references().first { $0.name == "main" })
    try f.write(".git/MERGE_HEAD", ref.hash + "\n")
    await #expect(throws: GitFailure.self) { try await f.repo.switchBranch(main) }
    #expect(try await f.repo.headPosition().branch == ref.fullName)
}
@Test func checkoutReferenceRejectsBranchOccupiedByAnotherWorktree() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["branch", "topic"])
    let ref = try #require(try await f.repo.references().first { $0.name == "topic" })
    try await f.git(["worktree", "add", f.url.appendingPathComponent("linked").path, "topic"])
    await #expect(throws: GitFailure.self) { try await f.repo.switchBranch(ref) }
    #expect(try await f.repo.headPosition().branch == "refs/heads/main")
}
