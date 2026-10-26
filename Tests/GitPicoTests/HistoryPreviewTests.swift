import Foundation
import GitCore
import Observation
import Testing
@testable import GitPico

actor RecordingHistoryReader: HistoryReading {
    var pages = 0
    var resolutions = 0
    var blockedScope: String?
    var continuation: CheckedContinuation<Void,Never>?
    var waiting = false
    func resolve(_ reference: String?, in repository: GitRepository) async throws -> HistoryRevision {
        resolutions += 1
        return try await repository.resolveHistory(reference)
    }
    func page(at revision: HistoryRevision, options: HistoryOptions, in repository: GitRepository) async throws -> CommitHistoryPage {
        pages += 1
        if let blockedScope, revision.identity.hasPrefix(blockedScope + ":") {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
            throw GitFailure("Late failure from a superseded preview")
        }
        return try await repository.historyPage(at: revision, options: options)
    }
    func block(_ scope: String) { blockedScope = scope; waiting = false }
    func release() { continuation?.resume(); continuation = nil; blockedScope = nil }
}
@MainActor private func settle(_ store: RepositoryStore) async throws {
    if let task = store.historyTask { await task.value }
    if let task = store.detailTask { await task.value }
    #expect(store.historyError == nil)
    #expect(!store.isLoadingHistory && !store.isBusy)
}

@Test @MainActor func previewCacheIsImmediateAndDoesNotRescanWorkingCopy() async throws {
    let reader = RecordingHistoryReader()
    let f = try await PreviewFixture.make(untracked: 3, reader: reader); defer { f.clean() }
    let head = try await f.repository.headPosition(), updated = f.store.lastUpdated
    let url = await f.repository.root
    let index = try Data(contentsOf: url.appendingPathComponent(".git/index"))
    for branch in [1,5] { f.store.navigate(.reference("refs/heads/preview/branch-\(branch)")); try await settle(f.store) }
    #expect(await reader.pages == 2)
    f.store.navigate(.reference("refs/heads/preview/branch-1"))
    // The cached selection is available in the same actor turn, before any asynchronous Git read.
    #expect(f.store.selectedCommit?.hash == f.tips[1])
    #expect(!f.store.isLoadingHistory)
    try await settle(f.store)
    #expect(await reader.pages == 2)
    #expect(await reader.resolutions == 3)
    #expect(f.store.lastUpdated == updated)
    #expect(try await f.repository.headPosition() == head)
    #expect(try Data(contentsOf: url.appendingPathComponent(".git/index")) == index)
    #expect(try String(contentsOf: url.appendingPathComponent("local-0"), encoding: .utf8) == "untracked")
}

@Test @MainActor func cachedTipValidationDoesNotPublishTheSameHistoryTwice() async throws {
    let f = try await PreviewFixture.make(); defer { f.clean() }
    f.store.navigate(.reference("refs/heads/preview/branch-1")); try await settle(f.store)
    f.store.navigate(.workingCopy)
    f.store.navigate(.reference("refs/heads/preview/branch-1"))
    // Observe after the immediate cache hit. Revalidation may read Git, but must
    // not invalidate the list again when it resolves to the very same page.
    let changed = HistoryPublicationFlag()
    withObservationTracking { _ = f.store.historyPresentation } onChange: { changed.mark() }
    try await settle(f.store)
    #expect(!changed.value)
}

private final class HistoryPublicationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func mark() { lock.lock(); defer { lock.unlock() }; changed = true }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return changed }
}

@Test func monthSectionsKeepIdentityAcrossBranchTipsAndDisambiguateRuns() throws {
    func commit(_ hash: Character, timestamp: String) throws -> Commit {
        let fields = [String(repeating: String(hash), count: 40), "", "Preview Test", "preview@example.invalid", timestamp, "Section test", "", ""]
        return try #require(GitParser.commits(Data((fields.joined(separator: "\0") + "\n").utf8)).first)
    }
    let first = try commit("a", timestamp: "1700000000")
    let second = try commit("b", timestamp: "1700001000")
    let olderMonth = try commit("c", timestamp: "1690000000")
    let branchA = HistoryPresentation.make(CommitHistoryPage(commits: [first, second], hasMore: false), firstParent: false)
    let branchB = HistoryPresentation.make(CommitHistoryPage(commits: [second], hasMore: false), firstParent: false)
    #expect(branchA.groups.first?.id == branchB.groups.first?.id)
    let interleaved = HistoryPresentation.make(CommitHistoryPage(commits: [first, olderMonth, second], hasMore: false), firstParent: false)
    #expect(interleaved.groups.count == 3)
    #expect(Set(interleaved.groups.map(\.id)).count == 3)
    #expect(interleaved.groups.flatMap(\.commits).map(\.hash) == [first.hash, olderMonth.hash, second.hash])
}

@Test @MainActor func previewCacheRevalidatesMovedTipAndExplicitRefresh() async throws {
    let reader = RecordingHistoryReader()
    let f = try await PreviewFixture.make(reader: reader); defer { f.clean() }
    f.store.navigate(.reference("refs/heads/preview/branch-1")); try await settle(f.store)
    f.store.navigate(.workingCopy)
    _ = try await GitProcess.run(["update-ref", "refs/heads/preview/branch-1", f.tips[5]], at: f.repository.root)
    f.store.navigate(.reference("refs/heads/preview/branch-1"))
    #expect(f.store.selectedCommit?.hash == f.tips[1])
    try await settle(f.store)
    #expect(f.store.selectedCommit?.hash == f.tips[5])
    #expect(await reader.pages == 2)
    f.store.refresh()
    let deadline = Date().addingTimeInterval(20)
    while f.store.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try await settle(f.store)
    #expect(await reader.pages == 3)
    #expect(f.store.selectedCommit?.hash == f.tips[5])
}

@Test @MainActor func previewOptionsHaveSeparateCacheEntries() async throws {
    let reader = RecordingHistoryReader()
    let f = try await PreviewFixture.make(reader: reader); defer { f.clean() }
    f.store.navigate(.history); try await settle(f.store)
    f.store.historyOptions.limit = 2; f.store.requestHistory(); try await settle(f.store)
    #expect(f.store.visibleCommits.count == 2 && f.store.historyPresentation.page.hasMore)
    f.store.historyOptions.firstParent = true; f.store.requestHistory(); try await settle(f.store)
    f.store.historyOptions.sortByDate = true; f.store.requestHistory(); try await settle(f.store)
    f.store.search = "Preview commit 17"; await f.store.searchHistory(); try await settle(f.store)
    #expect(f.store.visibleCommits.map(\.subject) == ["Preview commit 17"])
    #expect(!f.store.historyPresentation.page.hasMore)
    let pages = await reader.pages
    f.store.search = ""; await f.store.searchHistory(); try await settle(f.store)
    f.store.historyOptions = HistoryOptions(); f.store.requestHistory(); try await settle(f.store)
    #expect(f.store.visibleCommits.count == 24)
    #expect(await reader.pages == pages + 1)
}

@Test @MainActor func latePreviewFailureCannotOverwriteNewerBranchOrRepository() async throws {
    let reader = RecordingHistoryReader()
    let f = try await PreviewFixture.make(reader: reader); defer { f.clean() }
    await reader.block("refs/heads/preview/branch-1")
    f.store.navigate(.reference("refs/heads/preview/branch-1"))
    let old = f.store.historyTask
    let deadline = Date().addingTimeInterval(5)
    while !(await reader.waiting) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await reader.waiting)
    f.store.navigate(.reference("refs/heads/preview/branch-5")); try await settle(f.store)
    #expect(f.store.selectedCommit?.hash == f.tips[5])
    await reader.release(); await old?.value
    #expect(f.store.selectedCommit?.hash == f.tips[5])
    #expect(f.store.error == nil && f.store.historyError == nil)
    await reader.block("refs/heads/preview/branch-1")
    f.store.navigate(.reference("refs/heads/preview/branch-1"))
    let oldSession = f.store.historyTask
    let secondDeadline = Date().addingTimeInterval(5)
    while !(await reader.waiting) && Date() < secondDeadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await reader.waiting)
    // Opening even the same path starts a new session while the old reader is suspended.
    await f.store.open(f.repository.root)
    await reader.release(); await oldSession?.value
    #expect(f.store.historyCache.isEmpty && f.store.visibleCommits.isEmpty)
    #expect(f.store.historyError == nil && f.store.error == nil)
    f.store.navigate(.reference("refs/heads/preview/branch-5")); try await settle(f.store)
    #expect(await reader.pages == 4)
}

@Test @MainActor func rapidPreviewNavigationOnlyLoadsFinalSelection() async throws {
    let reader = RecordingHistoryReader()
    let f = try await PreviewFixture.make(reader: reader); defer { f.clean() }
    for branch in [1,2,3,4,5,6] { f.store.navigate(.reference("refs/heads/preview/branch-\(branch)")) }
    try await settle(f.store)
    #expect(f.store.selectedCommit?.hash == f.tips[6])
    #expect(await reader.pages == 1)
    #expect(await reader.resolutions == 1)
    #expect(f.store.backStack.count == 6)
    f.store.goBack(); try await settle(f.store)
    #expect(f.store.selectedCommit?.hash == f.tips[5])
}

@Test @MainActor func previewCacheEvictsOldPagesWithinCountAndCommitBudget() async throws {
    let f = try await PreviewFixture.make(); defer { f.clean() }
    let revision = try await f.repository.resolveHistory("main")
    let page = try await f.repository.historyPage(at: revision)
    let value = HistoryPresentation.make(page, firstParent: false)
    for size in 1...20 {
        var options = HistoryOptions(); options.limit = size
        f.store.cacheHistory(value, key: HistoryCacheKey(reference: "main", revision: revision, options: options))
    }
    #expect(f.store.historyCache.count == 16 && f.store.historyCacheOrder.count == 16)
    var first = HistoryOptions(); first.limit = 1
    #expect(f.store.cachedHistory(HistoryCacheKey(reference: "main", revision: revision, options: first)) == nil)
    // Large pages must also obey the total retained commit budget.
    let large = HistoryPresentation.make(CommitHistoryPage(commits: Array(repeating: page.commits[0], count: 11_000), hasMore: true), firstParent: false)
    for name in ["large-a", "large-b"] { f.store.cacheHistory(large, key: HistoryCacheKey(reference: name, revision: revision, options: HistoryOptions())) }
    #expect(f.store.historyCache.values.reduce(0) { $0 + $1.page.commits.count } <= 20_000)
}

@Test @MainActor func cancelledDetailIsReloadedForPreservedHistorySelection() async throws {
    let f = try await PreviewFixture.make(); defer { f.clean() }
    f.store.navigate(.history); try await settle(f.store)
    let selected = f.store.selectedCommit?.hash
    f.store.commitDetail = nil
    f.store.cancelPreviewWork()
    f.store.requestHistory()
    try await settle(f.store)
    #expect(f.store.selectedCommit?.hash == selected)
    #expect(f.store.commitDetail != nil)
}

@Test func sidebarOutlineRetainsNestedRemotesPinnedAndFilteredBranches() {
    let names = ["refs/heads/feature/a", "refs/heads/feature/b", "refs/heads/archive/c", "refs/tags/release/v1", "refs/remotes/team/origin/feature/a", "refs/remotes/team/origin/HEAD"]
    let refs = GitParser.references(Data(names.map { $0 + "\0" + String(repeating: "a", count: 40) + "\0\0\0" }.joined(separator: "\n").utf8))
    var input = SidebarOutlineInput(references: refs, remotes: ["team/origin"], pinned: [names[0]], archived: [names[2]], filter: "")
    let outline = SidebarOutline.make(input)
    #expect(outline.pinned.map(\.fullName) == [names[0]])
    #expect(outline.branches.first?.children?.first?.reference?.fullName == names[1])
    #expect(outline.archived.first?.children?.first?.reference?.fullName == names[2])
    #expect(outline.remotes["team/origin"]?.first?.children?.first?.reference?.fullName == names[4])
    input.filter = "feature/a"
    let filtered = SidebarOutline.make(input)
    #expect(filtered.branches.isEmpty && filtered.archived.isEmpty && filtered.tags.isEmpty)
    #expect(filtered.pinned.map(\.fullName) == [names[0]])
}

@Test @MainActor func indexWritePreservesPreviewWhenBranchTipIsUnchanged() async throws {
    let reader = RecordingHistoryReader()
    let f = try await PreviewFixture.make(untracked: 1, reader: reader); defer { f.clean() }
    f.store.navigate(.reference("refs/heads/preview/branch-1")); try await settle(f.store)
    let head = try await f.repository.headPosition()
    f.store.stage(f.store.changes)
    let deadline = Date().addingTimeInterval(20)
    while f.store.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try await settle(f.store)
    #expect(await reader.pages == 1)
    #expect(try await f.repository.headPosition() == head)
    #expect(f.store.snapshot?.changes.first?.isStaged == true)
}
