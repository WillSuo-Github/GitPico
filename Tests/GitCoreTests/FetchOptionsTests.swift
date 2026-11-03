import Foundation
import Synchronization
import Testing
@testable import GitCore

@Test func fetchSingleBranchSkipsOtherRefsAndLeavesWorktreeAndGitConfigAlone() async throws {
    let remote = try await Fixture.make(); defer { remote.clean() }
    let local = try await Fixture.make(); defer { local.clean() }
    try await remote.git(["branch", "other"])
    try await remote.git(["tag", "release-tag"])
    try await local.git(["remote", "add", "origin", remote.url.path])
    // Existing pruning preferences must not turn a narrow fetch into a prune.
    try await local.git(["config", "fetch.prune", "true"])
    try await local.git(["update-ref", "refs/remotes/origin/keep-local", "HEAD"])
    try local.write("readme.txt", "uncommitted edits\n")
    let head = try await local.repo.headPosition()
    let config = try Data(contentsOf: local.url.appendingPathComponent(".git/config"))
    let origin = try #require(try await local.repo.remoteConfigurations().first)
    var options = FetchOptions()
    options.branch = "main"
    options.tags = .skip
    options.prune = true
    options.useHTTP11 = true
    options.timeLimit = .extended
    try await local.repo.fetch(origin, options: options)

    let references = try await local.git(["for-each-ref", "--format=%(refname)", "refs/remotes", "refs/tags"]).text
    #expect(Set(references.split(separator: "\n")) == ["refs/remotes/origin/main", "refs/remotes/origin/keep-local"])
    #expect(try await local.repo.headPosition() == head)
    #expect(try String(contentsOf: local.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "uncommitted edits\n")
    #expect(try Data(contentsOf: local.url.appendingPathComponent(".git/config")) == config)
    #expect(try await local.git(["rev-parse", "--is-shallow-repository"]).text == "false\n")

    await #expect(throws: GitFailure.self) { try await local.repo.fetch(nil, options: options) }
    var invalid = options
    invalid.branch = "main:refs/heads/unintended"
    await #expect(throws: GitFailure.self) { try await local.repo.fetch(origin, options: invalid) }
}

@Test func fetchTimeoutRecordsExplicitDeadlineInsteadOfOnlySidebandFailure() async throws {
    let remote = try await Fixture.make(); defer { remote.clean() }
    let local = try await Fixture.make(); defer { local.clean() }
    try await local.git(["remote", "add", "origin", remote.url.path])
    let helper = local.url.appendingPathComponent("stall-upload")
    try Data("#!/bin/sh\nexec /bin/sleep 1\n".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    try await local.git(["config", "remote.origin.uploadpack", helper.path])
    let events = Mutex<[GitNetworkEvent]>([])
    let context = GitNetworkContext { event in events.withLock { $0.append(event) } }
    await #expect(throws: GitFailure.self) {
        try await GitNetworkContexts.$current.withValue(context) {
            try await GitProcess.run(["fetch", "origin"], at: local.url, timeout: 0.2)
        }
    }
    let terminal = events.withLock { $0.filter { $0.phase != .running } }
    #expect(terminal.count == 1 && terminal.first?.phase == .failed)
    #expect(terminal.first?.timedOut == true)
    #expect(terminal.first?.output.contains("timed out") == true)
}
