import Foundation
import Testing
@testable import GitCore

@Test func cleanupDetectsSquashMissingTrackingAndProtectsPinnedCurrentBranches() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["checkout", "-b", "topic"])
    try f.write("feature.txt", "one\n"); try await f.git(["add", "."]); try await f.git(["commit", "-m", "First"])
    try f.write("feature.txt", "one\ntwo\n"); try await f.git(["commit", "-am", "Second"])
    try await f.git(["branch", "pinned"])
    let pinned = try #require(try await f.repo.references().first { $0.name == "pinned" })
    try await f.repo.setReferenceOrganization(pinned, pinned: true)
    try await f.git(["remote", "add", "origin", f.url.path])
    try await f.git(["config", "branch.topic.remote", "origin"])
    try await f.git(["config", "branch.topic.merge", "refs/heads/topic"])
    try await f.git(["checkout", "main"])
    try await f.git(["merge", "--squash", "topic"]); try await f.git(["commit", "-m", "Squashed feature"])
    let candidates = try await f.repo.branchCleanupCandidates(base: "refs/heads/main", now: Date.distantFuture)
    let topic = try #require(candidates.first { $0.branch.name == "topic" })
    #expect(topic.reasons.contains("Combined patch found in base history"))
    #expect(topic.reasons.contains("Tracking branch missing locally"))
    #expect(topic.canArchive)
    #expect(candidates.first { $0.branch.name == "pinned" }?.canArchive == false)
    try await f.repo.archiveCleanupBranches([topic.branch])
    #expect(try await f.repo.referenceOrganization().archived.contains(topic.id))
    #expect(try await f.git(["show-ref", "--verify", topic.id]).status == 0)
    await #expect(throws: GitFailure.self) { try await f.repo.archiveCleanupBranches([pinned]) }
    let main = try #require(try await f.repo.references().first { $0.name == "main" })
    await #expect(throws: GitFailure.self) { try await f.repo.archiveCleanupBranches([main]) }
}

@Test func cleanupArchivingValidatesAllTipsBeforeChangingMetadata() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["branch", "a"]); try await f.git(["branch", "b"])
    let refs = try await f.repo.references().filter { ["a", "b"].contains($0.name) }
    try await f.git(["checkout", "b"]); try await f.git(["commit", "--allow-empty", "-m", "Moved"]); try await f.git(["checkout", "main"])
    await #expect(throws: GitFailure.self) { try await f.repo.archiveCleanupBranches(refs) }
    #expect(try await f.repo.referenceOrganization().archived.isEmpty)
}

@Test func cleanupProtectsBranchesCheckedOutInLinkedWorktrees() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["branch", "safe"]); try await f.git(["branch", "occupied"])
    try await f.git(["worktree", "add", f.url.appendingPathComponent("linked").path, "occupied"])
    let candidates = try await f.repo.branchCleanupCandidates(base: "refs/heads/main", now: .distantFuture)
    let occupied = try #require(candidates.first { $0.branch.name == "occupied" })
    let safe = try #require(candidates.first { $0.branch.name == "safe" })
    #expect(!occupied.canArchive && safe.canArchive)
    await #expect(throws: GitFailure.self) { try await f.repo.archiveCleanupBranches([safe.branch, occupied.branch]) }
    #expect(try await f.repo.referenceOrganization().archived.isEmpty)
}
