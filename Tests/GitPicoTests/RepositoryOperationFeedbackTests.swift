import Foundation
import GitCore
import Testing
@testable import GitPico

@MainActor private struct FetchFeedbackFixture {
    let base: WorkingAppFixture
    let store: RepositoryStore
    let root: URL
    let remote: URL

    static func make(delay: Double = 0.6, createRemote: Bool = true) async throws -> Self {
        let base = try await WorkingAppFixture.make()
        let root = await base.repository.root, remote = base.root.appendingPathComponent("Remote.git")
        if createRemote { _ = try await GitProcess.run(["clone", "--bare", root.path, remote.path], at: base.root) }
        _ = try await GitProcess.run(["remote", "add", "origin", remote.path], at: root)
        let upload = base.root.appendingPathComponent("upload-pack")
        try Data("#!/bin/sh\nsleep \(delay)\nexec /usr/bin/git-upload-pack \"$@\"\n".utf8).write(to: upload)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: upload.path)
        _ = try await GitProcess.run(["config", "remote.origin.uploadpack", upload.path], at: root)
        await base.store.openInPlace(root)
        return Self(base: base, store: base.store, root: root, remote: remote)
    }

    func clean() { store.clearOperationFeedback(); store.disconnectNetworkContext(); store.stopAutomaticRefresh(); base.clean() }
}

@Test @MainActor func manualFetchImmediatelyShowsFeedbackAndPermitsBrowsingWithoutWrites() async throws {
    let f = try await FetchFeedbackFixture.make(); defer { f.clean() }
    try await f.base.write("a.txt", "Keep local content\n")
    try await f.base.sync()
    f.store.commitSubject = "Keep this draft"
    let before = try await f.base.repository.headPosition()
    f.store.sync(.fetch)
    let feedback = try #require(f.store.operationFeedback)
    #expect(feedback.command == .fetch && feedback.phase == .running)
    #expect(f.store.isBusy && f.store.isFetching && f.store.canBrowseHistory)
    #expect(!f.store.canUseRepository && !f.store.canIntegrate && !f.store.canCommit)
    f.store.navigate(.history); await f.store.historyTask?.value
    #expect(f.store.destination == .history && !f.store.visibleCommits.isEmpty)
    f.store.stage(f.store.changes)
    #expect(try await GitProcess.run(["diff", "--cached", "--name-only"], at: f.root).data.isEmpty)
    await f.store.operationTask?.value
    #expect(!f.store.isBusy && !f.store.isFetching && f.store.error == nil)
    #expect(f.store.operationFeedback?.id == feedback.id && f.store.operationFeedback?.phase == .succeeded)
    #expect(f.store.feedbackNetworkRecord?.phase == .succeeded)
    #expect(f.store.commitSubject == "Keep this draft" && f.store.changes.contains { $0.path == "a.txt" })
    #expect(try await f.base.repository.headPosition() == before)
    #expect(try String(contentsOf: f.root.appendingPathComponent("a.txt"), encoding: .utf8) == "Keep local content\n")
    let other = f.base.root.appendingPathComponent("Other")
    _ = try await GitRepository.create(at: other)
    await f.store.openInPlace(other)
    #expect(f.store.operationFeedback == nil)
}

@Test @MainActor func failedFetchStaysVisibleAndRetryReplacesItsFeedback() async throws {
    let f = try await FetchFeedbackFixture.make(delay: 0.1, createRemote: false); defer { f.clean() }
    f.store.sync(.fetch); await f.store.operationTask?.value
    let failed = try #require(f.store.operationFeedback)
    #expect(failed.phase == .failed && f.store.error != nil && !f.store.isBusy)
    #expect(f.store.feedbackNetworkRecord?.phase == .failed)
    _ = try await GitProcess.run(["clone", "--bare", f.root.path, f.remote.path], at: f.base.root)
    f.store.error = nil
    f.store.sync(.fetch)
    let retry = try #require(f.store.operationFeedback)
    #expect(retry.id != failed.id && retry.phase == .running)
    f.store.dismissOperationFeedback(failed.id)
    #expect(f.store.operationFeedback?.id == retry.id)
    await f.store.operationTask?.value
    #expect(f.store.operationFeedback?.phase == .succeeded && f.store.error == nil)
    f.store.dismissOperationFeedback(retry.id)
    #expect(f.store.operationFeedback == nil)
}

@Test @MainActor func cancelledFetchDoesNotReportSuccess() async throws {
    let f = try await FetchFeedbackFixture.make(delay: 2); defer { f.clean() }
    f.store.sync(.fetch)
    let deadline = ContinuousClock.now + .seconds(5)
    while f.store.feedbackNetworkRecord == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let record = try #require(f.store.feedbackNetworkRecord)
    f.store.networkActivity?.cancel(record.id)
    await f.store.operationTask?.value
    #expect(!f.store.isBusy && f.store.operationFeedback?.phase == .cancelled)
    #expect(f.store.feedbackNetworkRecord?.phase == .cancelled)
}

@Test @MainActor func automaticFetchKeepsManualFeedbackQuiet() async throws {
    let f = try await FetchFeedbackFixture.make(delay: 0.2); defer { f.clean() }
    await f.store.fetchInBackground()
    #expect(f.store.operationFeedback == nil && !f.store.isFetching)
    #expect(f.store.networkActivity?.records.first?.phase == .succeeded)
}

extension FetchFeedbackFixture {
    func git(_ args: [String], at directory: URL? = nil) async throws -> String {
        try await GitProcess.run(args, at: directory ?? root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func trackedPeer() async throws -> URL {
        _ = try await git(["push", "-u", "origin", "main"])
        let peer = base.root.appendingPathComponent("Peer")
        _ = try await git(["clone", "--branch", "main", remote.path, peer.path], at: base.root)
        for (key, value) in [("user.name", "Feedback Test"), ("user.email", "feedback@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = try await git(["config", key, value], at: peer)
        }
        await store.refreshForFeedbackTest()
        return peer
    }

    func advance(_ directory: URL, file: String, text: String) async throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent(file))
        _ = try await git(["add", file], at: directory)
        _ = try await git(["commit", "-m", "Update " + file], at: directory)
    }

    func installHook(_ name: String, script: String) async throws {
        let hooks = base.root.appendingPathComponent("Hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let file = hooks.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        _ = try await git(["config", "core.hooksPath", hooks.path])
    }
}

extension RepositoryStore {
    fileprivate func refreshForFeedbackTest() async { refresh(); await operationTask?.value }
}

@Test @MainActor func directPushReportsSuccessAndRejectedPushStaysVisible() async throws {
    let f = try await FetchFeedbackFixture.make(delay: 0.1); defer { f.clean() }
    let peer = try await f.trackedPeer()
    try await f.advance(f.root, file: "local.txt", text: "local\n")
    try await f.base.sync()
    f.store.sync(.push)
    #expect(f.store.operationFeedback?.command == .push && f.store.operationFeedback?.isVisible == true)
    #expect(f.store.isBusy && !f.store.isFetching && !f.store.canIntegrate)
    await f.store.operationTask?.value
    #expect(f.store.operationFeedback?.phase == .succeeded && f.store.error == nil)
    #expect(try await f.git(["rev-parse", "refs/heads/main"], at: f.remote) == f.git(["rev-parse", "HEAD"]))
    try await f.advance(peer, file: "remote.txt", text: "remote\n")
    _ = try await f.git(["push", "--force", "origin", "main"], at: peer)
    f.store.sync(.push); await f.store.operationTask?.value
    #expect(f.store.operationFeedback?.phase == .failed && f.store.operationFeedback?.failure != nil)
    #expect(f.store.operationFeedback?.isVisible == true && !f.store.isBusy)
}

@Test @MainActor func reviewedFetchAndBranchPublicationUseTheSameFeedback() async throws {
    let f = try await FetchFeedbackFixture.make(delay: 0.1); defer { f.clean() }
    let remote = try #require(f.store.managedRemotes.first)
    f.store.runRemoteFetch(remote, prune: true, tags: true)
    #expect(f.store.operationFeedback?.command == .fetch && f.store.operationFeedback?.isVisible == true)
    await f.store.operationTask?.value
    #expect(f.store.operationFeedback?.phase == .succeeded)
    f.store.clearOperationFeedback()
    f.store.sync(.push)
    #expect(f.store.managementRequest != nil && !f.store.isBusy && f.store.operationFeedback == nil)
    let source = try #require(f.store.snapshot?.references.first { $0.isCurrent })
    let preview = try await f.base.repository.pushPreview(remote: remote, source: source, destination: "refs/heads/published", setUpstream: true)
    f.store.managementRequest = nil
    f.store.runRemotePush(preview)
    #expect(f.store.operationFeedback?.command == .push && f.store.operationFeedback?.isVisible == true)
    await f.store.operationTask?.value
    #expect(f.store.operationFeedback?.phase == .succeeded && f.store.error == nil)
    #expect(try await f.git(["rev-parse", "refs/heads/published"], at: f.remote) == source.hash)
    #expect(f.store.snapshot?.references.first(where: \.isCurrent)?.upstream == "origin/published")
}

@Test @MainActor func pullMergeAndRebaseRemainBusyUntilTheParentWorkflowFinishes() async throws {
    for policy in PullPolicy.allCases {
        let f = try await FetchFeedbackFixture.make(delay: 0.4); defer { f.clean() }
        let peer = try await f.trackedPeer()
        try await f.advance(peer, file: "remote.txt", text: "remote\n")
        _ = try await f.git(["push", "origin", "main"], at: peer)
        try await f.advance(f.root, file: "local.txt", text: "local\n")
        try await f.base.sync()
        f.store.reviewPull()
        let request = try #require(f.store.pullRequest)
        f.store.pullRequest = nil; f.store.runPull(request, policy: policy)
        #expect(f.store.operationFeedback?.command == .pull && f.store.operationFeedback?.isVisible == true)
        #expect(f.store.isBusy && !f.store.isFetching && !f.store.canBrowseHistory && !f.store.canIntegrate)
        await f.store.operationTask?.value
        #expect(f.store.operationFeedback?.phase == .succeeded && f.store.error == nil)
        #expect(f.store.snapshot?.behind == 0)
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("remote.txt").path))
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("local.txt").path))
    }
}

@Test @MainActor func synchronizeDoesNotFinishWhenPullSucceedsBeforePush() async throws {
    let f = try await FetchFeedbackFixture.make(delay: 0.1); defer { f.clean() }
    _ = try await f.trackedPeer()
    try await f.advance(f.root, file: "local.txt", text: "local\n")
    try await f.installHook("pre-push", script: "sleep 1")
    try await f.base.sync()
    f.store.syncAll()
    let request = try #require(f.store.pullRequest)
    f.store.pullRequest = nil; f.store.runPull(request, policy: .merge)
    let deadline = ContinuousClock.now + .seconds(5)
    while f.store.feedbackNetworkRecord?.command != "push" && f.store.isBusy && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(f.store.feedbackNetworkRecord?.command == "push" && f.store.feedbackNetworkRecord?.phase == .running)
    #expect(f.store.networkActivity?.records.contains { $0.command == "pull" && $0.phase == .succeeded } == true)
    #expect(f.store.isBusy && f.store.operationFeedback?.command == .synchronize && f.store.operationFeedback?.phase == .running)
    #expect(f.store.operationFeedback?.isRefreshing == false)
    await f.store.operationTask?.value
    #expect(f.store.operationFeedback?.phase == .succeeded && f.store.error == nil)
    #expect(try await f.git(["rev-parse", "refs/heads/main"], at: f.remote) == f.git(["rev-parse", "HEAD"]))
}

@Test @MainActor func pullConflictDoesNotReportCompletionAndAbortRestoresWork() async throws {
    let f = try await FetchFeedbackFixture.make(delay: 0.1); defer { f.clean() }
    let peer = try await f.trackedPeer()
    try await f.advance(peer, file: "a.txt", text: "remote\n")
    _ = try await f.git(["push", "origin", "main"], at: peer)
    try await f.advance(f.root, file: "a.txt", text: "local\n")
    try await f.base.sync()
    let before = try await f.base.repository.headPosition()
    f.store.reviewPull()
    let request = try #require(f.store.pullRequest)
    f.store.pullRequest = nil; f.store.runPull(request, policy: .merge)
    await f.store.operationTask?.value
    #expect(f.store.operationFeedback?.command == .pull && f.store.operationFeedback?.phase == .failed)
    #expect(f.store.snapshot?.operation == .merge && f.store.changes.contains(where: \.isConflicted))
    #expect(f.store.operationFeedback?.failure != nil && f.store.operationFeedback?.isVisible == true)
    f.store.error = nil; f.store.abortOperation()
    #expect(f.store.operationFeedback?.command == .local)
    await f.store.operationTask?.value
    #expect(f.store.error == nil && f.store.snapshot?.operation == RepositoryOperation.none)
    #expect(try await f.base.repository.headPosition() == before)
    #expect(try String(contentsOf: f.root.appendingPathComponent("a.txt"), encoding: .utf8) == "local\n")
}

@Test @MainActor func automaticStashKeepsPullIdentityThroughRecovery() async throws {
    let f = try await FetchFeedbackFixture.make(delay: 0.3); defer { f.clean() }
    let peer = try await f.trackedPeer()
    try await f.advance(peer, file: "remote.txt", text: "remote\n")
    _ = try await f.git(["push", "origin", "main"], at: peer)
    try await f.base.write("b.txt", "Keep staged work\n")
    _ = try await f.git(["add", "b.txt"])
    try await f.base.sync()
    let head = try #require(f.store.snapshot?.head)
    let request = AutomaticStashRequest(title: "Pull…", refresh: .workingTree, feedback: .pull) {
        try await $0.pull(policy: .merge, expectedHead: head, expectedUpstream: "origin/main")
    }
    f.store.runAutomaticStash(request, message: "Keep work", restoreAfter: true)
    #expect(f.store.operationFeedback?.command == .pull && f.store.operationFeedback?.isVisible == true)
    await f.store.operationTask?.value
    #expect(f.store.error == nil && f.store.operationFeedback?.phase == .succeeded)
    #expect(f.store.automaticStash == nil && f.store.snapshot?.stashes.isEmpty == true)
    #expect(f.store.staged.map(\.path) == ["b.txt"])
    #expect(try String(contentsOf: f.root.appendingPathComponent("b.txt"), encoding: .utf8) == "Keep staged work\n")
}

@Test @MainActor func localActionsDelayFeedbackAndCommitHooksKeepProgressVisible() async throws {
    let f = try await FetchFeedbackFixture.make(delay: 0); defer { f.clean() }
    try await f.base.write("a.txt", "Commit this\n"); try await f.base.sync()
    f.store.stage(f.store.changes)
    #expect(f.store.operationFeedback?.command == .local && f.store.operationFeedback?.isVisible == false)
    await f.store.operationTask?.value
    #expect(f.store.staged.map(\.path) == ["a.txt"])
    try await f.installHook("pre-commit", script: "sleep 1")
    f.store.commitSubject = "Slow hook commit"
    f.store.commit()
    #expect(f.store.operationFeedback?.isVisible == false)
    try await Task.sleep(for: .milliseconds(300))
    #expect(f.store.isBusy && f.store.operationFeedback?.isVisible == true && f.store.operationFeedback?.phase == .running)
    await f.store.operationTask?.value
    #expect(f.store.operationFeedback?.phase == .succeeded && f.store.commitFeedback == "Commit created.")
    #expect(f.store.snapshot?.commits.first?.subject == "Slow hook commit")
    try await f.installHook("pre-commit", script: "echo 'Hook refused commit' >&2\nexit 1")
    try await f.base.write("b.txt", "Keep this staged\n"); try await f.base.sync()
    f.store.stage(f.store.changes); await f.store.operationTask?.value
    f.store.commitSubject = "Rejected commit"; f.store.commit(); await f.store.operationTask?.value
    #expect(f.store.operationFeedback?.phase == .failed && f.store.operationFeedback?.isVisible == true)
    #expect(f.store.staged.map(\.path) == ["b.txt"] && f.store.commitSubject == "Rejected commit")
}

@Test @MainActor func failedConnectionTestDoesNotShowSuccessAndBackgroundFetchDoesNotReplaceManualResult() async throws {
    let f = try await FetchFeedbackFixture.make(delay: 0, createRemote: false); defer { f.clean() }
    f.store.testRemote("origin"); await f.store.operationTask?.value
    let failed = try #require(f.store.operationFeedback)
    #expect(failed.phase == .failed && failed.isVisible && failed.failure != nil)
    await f.store.fetchInBackground()
    #expect(f.store.operationFeedback?.id == failed.id && f.store.operationFeedback?.phase == .failed)
}

@Test @MainActor func failedCloneFromAnOpenRepositoryCannotFinishWithSuccess() async throws {
    let f = try await FetchFeedbackFixture.make(delay: 0); defer { f.clean() }
    let before = try await f.base.repository.headPosition()
    f.store.createRepository(at: f.base.root.appendingPathComponent("FailedClone"), source: f.base.root.appendingPathComponent("MissingSource.git").path, allowLocalTransport: true)
    let deadline = ContinuousClock.now + .seconds(5)
    while f.store.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!f.store.isBusy && f.store.error != nil)
    #expect(f.store.operationFeedback?.phase == .failed && f.store.operationFeedback?.isVisible == true)
    let after = try await f.base.repository.headPosition()
    #expect(f.store.snapshot?.root == f.root && after == before)
}
