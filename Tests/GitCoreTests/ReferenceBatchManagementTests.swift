import Foundation
import Testing
@testable import GitCore

private func referenceBatchFixture() async throws -> (Fixture, [Reference]) {
    let f = try await Fixture.make()
    for name in ["alpha", "beta", "untouched"] { _ = try await f.git(["branch", name]) }
    _ = try await f.git(["tag", "-a", "--no-sign", "-m", "Keep annotation", "batch-tag"])
    let refs = try await f.repo.references().filter { ["alpha", "beta", "batch-tag"].contains($0.name) }
    return (f, refs)
}

@Suite struct ReferenceBatchManagementTests {

@Test func referenceBatchDeletionRemovesAllTargetsAndKeepsRecoveryAndUnselectedReferences() async throws {
    let (f, refs) = try await referenceBatchFixture(); defer { f.clean() }
    let branches = refs.filter(\.isLocal)
    try await f.repo.setReferenceOrganization(branches, archived: true, pinned: true)
    _ = try await f.git(["config", "branch.alpha.remote", "origin"])
    try await f.repo.deleteReferences(refs)
    let remaining = try await f.repo.references()
    #expect(remaining.contains { $0.name == "main" } && remaining.contains { $0.name == "untouched" })
    #expect(Set(remaining.map(\.fullName)).isDisjoint(with: refs.map(\.fullName)))
    let backups = try await f.repo.referenceBackups()
    #expect(Set(backups.map(\.fullName)) == Set(refs.map(\.fullName)))
    #expect(try await f.repo.referenceOrganization().archived.isEmpty)
    #expect(try await f.repo.referenceOrganization().pinned.isEmpty)
    #expect(try await f.git(["config", "--get", "branch.alpha.remote"], allowed: [0, 1]).status == 1)
    let tag = try #require(backups.first(where: { $0.isTag }))
    try await f.repo.restoreReferenceBackup(tag, name: "recovered-tag")
    #expect(try await f.git(["rev-parse", "refs/tags/recovered-tag"]).text.trimmingCharacters(in: .newlines) == tag.hash)
    #expect(try await f.git(["cat-file", "-p", tag.hash]).text.contains("Keep annotation"))
}

@Test func referenceBatchDeletionRejectsUnmergedSelectionBeforeDeletingAnyBranch() async throws {
    let (f, refs) = try await referenceBatchFixture(); defer { f.clean() }
    _ = try await f.git(["switch", "beta"])
    try f.write("new.txt", "not merged\n"); _ = try await f.git(["add", "."]); _ = try await f.git(["commit", "-m", "Unmerged"])
    _ = try await f.git(["switch", "main"])
    let current = try await f.repo.references().filter { ["alpha", "beta"].contains($0.name) }
    await #expect(throws: GitFailure.self) { try await f.repo.deleteReferences(current) }
    #expect(try await f.repo.referenceBackups().isEmpty)
    #expect(try await f.repo.references().filter { ["alpha", "beta"].contains($0.name) }.count == 2)
    try await f.repo.deleteReferences(current, force: true)
    #expect(try await f.repo.references().allSatisfy { !["alpha", "beta"].contains($0.name) })
    #expect(try await f.repo.references().contains { $0.fullName == refs.first(where: { $0.isTag })?.fullName })
}

@Test(arguments: ["current", "worktree", "stale"])
func referenceBatchDeletionRejectsProtectedOrChangedMembersWithoutPartialDeletion(reason: String) async throws {
    let (f, refs) = try await referenceBatchFixture(); defer { f.clean() }
    var selected = refs.filter(\.isLocal)
    if reason == "current" { selected.append(try #require(try await f.repo.references().first(where: { $0.isCurrent }))) }
    if reason == "worktree" { _ = try await f.git(["worktree", "add", f.url.appendingPathComponent("linked").path, "beta"]) }
    if reason == "stale" { _ = try await f.git(["branch", "-D", "beta"]) }
    await #expect(throws: GitFailure.self) { try await f.repo.deleteReferences(selected, force: true) }
    #expect(try await f.repo.references().contains { $0.name == "alpha" })
    #expect(try await f.repo.referenceBackups().isEmpty)
}

@Test func referenceBatchDeletionUsesOneTransactionWhenAReferenceCannotBeLocked() async throws {
    let (f, refs) = try await referenceBatchFixture(); defer { f.clean() }
    let lock = f.url.appendingPathComponent(".git/refs/heads/beta.lock")
    try Data().write(to: lock)
    await #expect(throws: GitFailure.self) { try await f.repo.deleteReferences(refs) }
    let remaining = Set(try await f.repo.references().map(\.fullName))
    #expect(Set(refs.map(\.fullName)).isSubset(of: remaining))
    #expect(try await f.repo.referenceBackups().count == refs.count)
}

@Test func referenceBatchOrganizationValidatesAllMembersBeforeWriting() async throws {
    let (f, refs) = try await referenceBatchFixture(); defer { f.clean() }
    let branches = refs.filter(\.isLocal)
    try await f.repo.setReferenceOrganization(branches, pinned: true)
    #expect(try await f.repo.referenceOrganization().pinned == Set(branches.map(\.fullName)))
    _ = try await f.git(["branch", "-D", "beta"])
    await #expect(throws: GitFailure.self) { try await f.repo.setReferenceOrganization(branches, archived: true) }
    #expect(try await f.repo.referenceOrganization().archived.isEmpty)
    await #expect(throws: GitFailure.self) { try await f.repo.setReferenceOrganization(refs, pinned: false) }
    #expect(try await f.repo.referenceOrganization().pinned == Set(branches.map(\.fullName)))
    await #expect(throws: GitFailure.self) { try await f.repo.deleteReferences([branches[0], branches[0]]) }
}
}
