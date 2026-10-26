import Foundation
import Testing
@testable import GitCore

@Test func bulkRemoteReadPreservesMultiValuesIncludesAndDottedNames() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let include = f.url.appendingPathComponent("included-config")
    try Data("[remote \"Team.origin\"]\n\turl = https://example.invalid/one\n\turl = https://example.invalid/two\n\tpushurl = ssh://example.invalid/push\n\tfetch = +refs/heads/a:refs/remotes/Team.origin/a\n\tfetch = +refs/heads/b:refs/remotes/Team.origin/b\n".utf8).write(to: include)
    _ = try await f.git(["config", "include.path", include.path])
    _ = try await f.git(["config", "remote.Team.origin.url", "https://example.invalid/local"])
    _ = try await f.git(["config", "remote.empty.url", ""])
    let trace = GitCommandTrace()
    let remotes = try await GitCommandTrace.$current.withValue(trace) { try await f.repo.remoteConfigurations() }
    let team = try #require(remotes.first { $0.name == "Team.origin" })
    #expect(team.fetchURLs == ["https://example.invalid/one", "https://example.invalid/two", "https://example.invalid/local"])
    #expect(team.pushURLs == ["ssh://example.invalid/push"] && team.refspecs.count == 2)
    let empty = try #require(remotes.first { $0.name == "empty" })
    #expect(empty.fetchURLs.isEmpty && empty.pushURLs.isEmpty && empty.fetchURL.isEmpty)
    #expect(await trace.samples.count == 2)
}

@Test func boundedOpenSnapshotKeepsHistoryAndDefersExactCount() async throws {
    let f = try await Fixture.make(initialCommit: false); defer { f.clean() }
    try f.write("readme", "one\n"); _ = try await f.git(["add", "."]); _ = try await f.git(["commit", "-m", "Initial"])
    try f.write("readme", "two\n"); _ = try await f.git(["add", "."]); _ = try await f.git(["commit", "-m", "Second"])
    var options = HistoryOptions(); options.limit = 1
    let trace = GitCommandTrace()
    let bounded = try await GitCommandTrace.$current.withValue(trace) { try await f.repo.snapshot(options: options, countHistory: false) }
    #expect(bounded.commits.count == 1 && bounded.historyCount == 1 && !bounded.historyCountIsExact)
    #expect(!(await trace.samples).contains { $0.command == "rev-list" })
    let full = try await f.repo.snapshot(options: options)
    #expect(full.commits == bounded.commits && full.historyCount == 2 && full.historyCountIsExact)
    let all = try await f.repo.snapshot(countHistory: false)
    #expect(all.historyCount == 2 && all.historyCountIsExact && all.head == bounded.head)
}

@Test func eventDrivenGitWaitPreservesOutputLimitsErrorsAndTimeout() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let output = try await f.git(["rev-parse", "--show-toplevel"])
    let actual = URL(fileURLWithPath: output.text.trimmingCharacters(in: .newlines)).resolvingSymlinksInPath()
    #expect(actual == f.url.resolvingSymlinksInPath())
    let absent = try await f.git(["config", "--get", "gitpico.missing"], allowed: [0, 1])
    #expect(absent.status == 1 && absent.data.isEmpty)
    await #expect(throws: GitFailure.self) { try await GitProcess.run(["rev-parse", "--show-toplevel"], at: f.url, maxOutputBytes: 1) }
    do {
        _ = try await GitProcess.run(["hash-object", "--stdin"], at: f.url, timeout: 0.000001, input: Data(repeating: 65, count: 8 * 1024 * 1024))
        Issue.record("Expected a command timeout")
    } catch let error as GitFailure { #expect(error.message.contains("timed out")) }
    #expect(try await f.repo.snapshot().branch == "main")
    let write = Task { try await GitProcess.run(["config", "gitpico.cancelledwrite", "finished"], at: f.url) }
    write.cancel()
    _ = try await write.value
    #expect(try await f.git(["config", "--get", "gitpico.cancelledwrite"]).text.trimmingCharacters(in: .newlines) == "finished")
}
