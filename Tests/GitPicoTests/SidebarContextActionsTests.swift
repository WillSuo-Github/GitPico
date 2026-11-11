import Foundation
import GitCore
import Testing
@testable import GitPico

@Suite struct SidebarContextActionsTests {

@Test @MainActor func sidebarContextSelectionRequiresEverySelectedTargetToSupportAnAction() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    for name in ["alpha", "beta"] { _ = try await GitProcess.run(["branch", name], at: f.repository.root) }
    _ = try await GitProcess.run(["tag", "tag-a"], at: f.repository.root)
    _ = try await GitProcess.run(["update-ref", "refs/remotes/origin/remote-a", "HEAD"], at: f.repository.root)
    try await f.sync()
    let refs = try #require(f.store.snapshot?.references)
    let branches: Set<Destination> = [.reference("refs/heads/beta"), .reference("refs/heads/alpha")]
    let group = SidebarContextSelection(branches, references: refs)
    #expect(group.onlyLocalBranches && group.canDelete && group.copiedNames == "alpha\nbeta")
    let mixedTags = SidebarContextSelection(branches.union([.reference("refs/tags/tag-a")]), references: refs)
    #expect(mixedTags.onlyReferences && !mixedTags.onlyLocalBranches && mixedTags.canDelete)
    let mixedRemote = SidebarContextSelection(branches.union([.reference("refs/remotes/origin/remote-a")]), references: refs)
    #expect(mixedRemote.onlyReferences && !mixedRemote.onlyLocalBranches && !mixedRemote.canDelete)
    for extra in [Destination.workingCopy, .reference("refs/heads/missing")] {
        let invalid = SidebarContextSelection(branches.union([extra]), references: refs)
        #expect(!invalid.onlyReferences && !invalid.onlyLocalBranches && !invalid.canDelete)
    }
    #expect(!SidebarContextSelection(branches.union([.reference("refs/heads/main")]), references: refs).canDelete)
}

@Test @MainActor func sidebarBatchDeletionUsesAllReviewedTargetsAndRejectsAnotherRepositoryToken() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    for name in ["alpha", "beta", "untouched"] { _ = try await GitProcess.run(["branch", name], at: f.repository.root) }
    try await f.sync()
    let refs = try #require(f.store.snapshot?.references.filter { ["alpha", "beta"].contains($0.name) })
    f.store.deleteSidebarReferences(refs, force: false, repositoryToken: UUID())
    #expect(f.store.operationTask == nil && f.store.error != nil)
    #expect(try await f.repository.references().filter { ["alpha", "beta"].contains($0.name) }.count == 2)
    f.store.error = nil
    f.store.deleteSidebarReferences(refs, force: false, repositoryToken: f.store.repositoryToken)
    await f.finish()
    #expect(f.store.error == nil)
    #expect(f.store.snapshot?.references.allSatisfy { !["alpha", "beta"].contains($0.name) } == true)
    #expect(f.store.snapshot?.references.contains { $0.name == "untouched" } == true)
}
}
