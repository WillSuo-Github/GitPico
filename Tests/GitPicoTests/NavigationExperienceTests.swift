import Foundation
import GitCore
import Testing
@testable import GitPico

@MainActor private func finishPreview(_ store: RepositoryStore) async {
    await store.historyTask?.value
    await store.detailTask?.value
    #expect(store.historyError == nil && store.error == nil)
}

@Test @MainActor func revisitingPagesRestoresQueryPageOptionsWithoutRepositoryVisits() async throws {
    let f = try await PreviewFixture.make(); defer { f.clean() }
    f.store.navigate(.reference("refs/heads/preview/branch-1")); await finishPreview(f.store)
    f.store.search = "Preview commit 1"; await f.store.searchHistory(); await finishPreview(f.store)
    f.store.historyOptions.limit = 5; f.store.historyOptions.firstParent = true
    f.store.requestHistory(); await finishPreview(f.store)
    let first = try #require(f.store.visibleCommits.dropFirst(2).first)
    f.store.selectCommit(first)
    let firstOptions = f.store.historyOptions
    f.store.navigate(.reference("refs/heads/preview/branch-5")); await finishPreview(f.store)
    let second = try #require(f.store.visibleCommits.dropFirst().first)
    f.store.selectCommit(second)
    f.store.navigate(.reference("refs/heads/preview/branch-1")); await finishPreview(f.store)
    #expect(f.store.search == "Preview commit 1" && f.store.historyOptions == firstOptions)
    #expect(f.store.selectedCommit?.hash == first.hash)
    #expect(f.store.historyReveal?.hash == first.hash && f.store.historyReveal?.atTop == false)
    f.store.navigate(.reference("refs/heads/preview/branch-5")); await finishPreview(f.store)
    #expect(f.store.search.isEmpty && f.store.selectedCommit?.hash == second.hash)
    f.store.navigate(.workingCopy)
    #expect(!f.store.canGoBack && !f.store.canGoForward)
    await f.store.open(f.repository.root)
    #expect(f.store.navigationBookmarks.isEmpty && !f.store.canGoBack)
}

actor GatedTipReader: HistoryReading {
    var shouldWait = false
    var waiting = false
    var continuation: CheckedContinuation<Void,Never>?
    func block() { shouldWait = true }
    func release() { shouldWait = false; continuation?.resume(); continuation = nil }
    func resolve(_ reference: String?, in repository: GitRepository) async throws -> HistoryRevision {
        let revision = try await repository.resolveHistory(reference)
        if shouldWait { waiting = true; await withCheckedContinuation { continuation = $0 } }
        return revision
    }
    func page(at revision: HistoryRevision, options: HistoryOptions, in repository: GitRepository) async throws -> CommitHistoryPage {
        try await repository.historyPage(at: revision, options: options)
    }
}
@Test @MainActor func warmTipRevalidationDoesNotResetNewUserSelection() async throws {
    let reader = GatedTipReader()
    let f = try await PreviewFixture.make(reader: reader); defer { f.clean() }
    f.store.navigate(.history); await finishPreview(f.store)
    f.store.navigate(.workingCopy)
    await reader.block()
    f.store.navigate(.history)
    let deadline = Date().addingTimeInterval(5)
    while !(await reader.waiting) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await reader.waiting)
    let commit = try #require(f.store.visibleCommits.dropFirst(4).first)
    f.store.selectCommit(commit)
    await reader.release(); await finishPreview(f.store)
    #expect(f.store.selectedCommit?.hash == commit.hash)
}

@Test @MainActor func branchPreviewAndCheckoutRemainSeparateAndBusyCommandsAreDisabled() async throws {
    let f = try await PreviewFixture.make(); defer { f.clean() }
    f.store.navigate(.reference("refs/heads/preview/branch-1")); await finishPreview(f.store)
    let ref = try #require(f.store.previewedReference)
    #expect(try await f.repository.headPosition().branch == "refs/heads/main")
    #expect(f.store.navigationSubtitle == "History · preview/branch-1")
    #expect(f.store.checkoutUnavailableReason(ref) == nil)
    f.store.isBusy = true
    #expect(!f.store.canUseRepository && !f.store.canIntegrate && !f.store.canSynchronize)
    f.store.switchBranch(ref)
    #expect(try await f.repository.headPosition().branch == "refs/heads/main")
    f.store.isBusy = false
    f.store.switchBranch(ref)
    let deadline = Date().addingTimeInterval(20)
    while f.store.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    await finishPreview(f.store)
    #expect(try await f.repository.headPosition().branch == ref.fullName)
    #expect(f.store.previewedReference?.isCurrent == true)
    #expect(f.store.checkoutUnavailableReason(try #require(f.store.previewedReference)) != nil)
}

@Test @MainActor func navigationCancelsPendingSearchFocusAndBoundsBookmarks() async throws {
    let f = try await PreviewFixture.make(); defer { f.clean() }
    for index in 0..<120 {
        f.store.searchFocusRequest = UUID()
        f.store.navigate(.reference("commit-\(index)"))
        #expect(f.store.searchFocusRequest == nil)
    }
    f.store.cancelPreviewWork()
    #expect(!f.store.canGoBack && !f.store.canGoForward)
    #expect(f.store.navigationBookmarks.count == 32)
    #expect(f.store.navigationBookmarkOrder.count == 32)
}

@Test @MainActor func navigationCapturesQueryBeforeDebouncedSearchStarts() async throws {
    let f = try await PreviewFixture.make(); defer { f.clean() }
    f.store.navigate(.history); await finishPreview(f.store)
    f.store.search = "Preview commit 17"
    f.store.navigate(.workingCopy)
    f.store.navigate(.history); await finishPreview(f.store)
    #expect(f.store.historyOptions.query == f.store.search)
    #expect(f.store.visibleCommits.map(\.subject) == ["Preview commit 17"])
}
@Test @MainActor func rewrittenBranchRevealsTipWhenBookmarkedCommitDisappears() async throws {
    let f = try await PreviewFixture.make(); defer { f.clean() }
    f.store.navigate(.reference("refs/heads/preview/branch-1")); await finishPreview(f.store)
    f.store.selectCommit(try #require(f.store.visibleCommits.dropFirst(3).first))
    f.store.navigate(.workingCopy)
    _ = try await GitProcess.run(["update-ref", "refs/heads/preview/branch-1", f.tips[6]], at: f.repository.root)
    f.store.navigate(.reference("refs/heads/preview/branch-1")); await finishPreview(f.store)
    #expect(f.store.selectedCommit?.hash == f.tips[6])
    #expect(f.store.historyReveal?.hash == f.tips[6] && f.store.historyReveal?.atTop == true)
}
