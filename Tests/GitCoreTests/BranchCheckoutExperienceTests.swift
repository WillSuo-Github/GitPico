import Foundation
import Testing
@testable import GitCore

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
