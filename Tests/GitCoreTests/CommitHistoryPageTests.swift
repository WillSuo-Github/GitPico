import Foundation
import Testing
@testable import GitCore

@Test func historyPageUsesImmutableTipAndBoundedPagination() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    for i in 1...4 { try await f.git(["commit", "--allow-empty", "-m", "Message \(i)"]) }
    let revision = try await f.repo.resolveHistory("refs/heads/main")
    try await f.git(["commit", "--allow-empty", "-m", "After resolution"])
    var options = HistoryOptions(); options.limit = 2
    let page = try await f.repo.historyPage(at: revision, options: options)
    #expect(page.commits.map(\.subject) == ["Message 4", "Message 3"])
    #expect(page.hasMore && page.totalCount == nil)
    options.limit = 20
    let complete = try await f.repo.historyPage(at: revision, options: options)
    #expect(complete.commits.count == 5 && !complete.hasMore && complete.totalCount == 5)
    options.query = "message 3"
    #expect(try await f.repo.historyPage(at: revision, options: options).commits.map(\.subject) == ["Message 3"])
}
@Test func historyPageAllReferencesAndFirstParentHandleMergeAndAnnotatedTag() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["checkout", "-b", "topic"])
    try await f.git(["commit", "--allow-empty", "-m", "Topic change"])
    try await f.git(["tag", "-a", "v1", "-m", "Tag"])
    try await f.git(["checkout", "main"])
    try await f.git(["commit", "--allow-empty", "-m", "Main change"])
    try await f.git(["merge", "--no-ff", "topic", "-m", "Merge topic"])
    let all = try await f.repo.resolveHistory(nil)
    #expect(try await f.repo.historyPage(at: all).commits.count == 4)
    let revision = try await f.repo.resolveHistory("refs/heads/main")
    var options = HistoryOptions(); options.firstParent = true; options.sortByDate = true
    #expect(try await f.repo.historyPage(at: revision, options: options).commits.map(\.subject) == ["Merge topic", "Main change", "Initial | commit"])
    let tag = try await f.repo.resolveHistory("refs/tags/v1")
    #expect(try await f.repo.historyPage(at: tag).commits.first?.subject == "Topic change")
}
@Test func historyPageUnbornAndInvalidInputs() async throws {
    let f = try await Fixture.make(initialCommit: false); defer { f.clean() }
    let revision = try await f.repo.resolveHistory(nil)
    #expect(try await f.repo.historyPage(at: revision).totalCount == 0)
    await #expect(throws: GitFailure.self) { try await f.repo.resolveHistory("--all") }
    await #expect(throws: GitFailure.self) { try await f.repo.historyPage(at: .reference("bad", hash: "--all")) }
    var options = HistoryOptions(); options.limit = 20_001
    await #expect(throws: GitFailure.self) { try await f.repo.historyPage(at: revision, options: options) }
}
@Test func historyReadHonorsCancellationBeforeLaunching() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await GitProcess.run(["rev-parse", "HEAD"], at: f.url, cancellable: true)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}
