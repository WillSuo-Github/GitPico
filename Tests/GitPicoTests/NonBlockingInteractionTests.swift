import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@MainActor private func waitUntilReady(
    timeout: TimeInterval = 10,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), sourceLocation: sourceLocation)
}

@MainActor private func findSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    for subview in view.subviews {
        if let found = findSubview(of: type, in: subview) { return found }
    }
    return nil
}

@MainActor private func makeGatedPullPushFixture() async throws -> (fixture: WorkingAppFixture, remote: URL, peer: URL, hooks: URL) {
    let fixture = try await WorkingAppFixture.make()
    let root = await fixture.repository.root
    let remote = fixture.root.appendingPathComponent("origin.git", isDirectory: true)
    let peer = fixture.root.appendingPathComponent("peer", isDirectory: true)
    let hooks = fixture.root.appendingPathComponent("hooks", isDirectory: true)
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    _ = try await GitProcess.run(["init", "--bare", remote.path], at: root)
    _ = try await GitProcess.run(["remote", "add", "origin", remote.path], at: root)
    _ = try await GitProcess.run(["push", "-u", "origin", "main"], at: root)
    _ = try await GitProcess.run(["branch", "feature"], at: root)
    _ = try await GitProcess.run(["clone", "--branch", "main", remote.path, peer.path], at: fixture.root)
    for (key, value) in [
        ("user.name", "Interaction Test"),
        ("user.email", "interaction@example.invalid"),
        ("commit.gpgsign", "false"),
        ("core.hooksPath", "/dev/null")
    ] {
        _ = try await GitProcess.run(["config", key, value], at: peer)
    }
    try await fixture.sync()
    return (fixture, remote, peer, hooks)
}

private func gateScript(path: String, execCommand: String) -> String {
    """
    #!/bin/sh
    count=0
    while [ ! -f "\(path)" ] && [ "$count" -lt 600 ]; do
        sleep 0.05
        count=$((count + 1))
    done
    \(execCommand)
    """
}

@Test @MainActor func pullAndPushKeepSidebarNavigationHistoryAndWorkingCopyInteractive() async throws {
    let (fixture, remote, peer, hooks) = try await makeGatedPullPushFixture()
    defer { fixture.clean() }
    let root = await fixture.repository.root

    try Data("remote change\n".utf8).write(to: peer.appendingPathComponent("remote.txt"))
    _ = try await GitProcess.run(["add", "remote.txt"], at: peer)
    _ = try await GitProcess.run(["commit", "-m", "Remote update"], at: peer)
    _ = try await GitProcess.run(["push", "origin", "main"], at: peer)

    let pullGate = fixture.root.appendingPathComponent("pull.gate")
    defer { try? Data().write(to: pullGate) }
    let uploadPack = fixture.root.appendingPathComponent("upload-pack.sh")
    try Data(gateScript(path: pullGate.path, execCommand: "exec /usr/bin/git upload-pack \"$@\"").utf8).write(to: uploadPack)
    _ = try await GitProcess.run(["config", "remote.origin.uploadpack", "/bin/sh '" + uploadPack.path + "'"], at: root)

    try await fixture.sync()
    fixture.store.reviewPull()
    let pullRequest = try #require(fixture.store.pullRequest)
    fixture.store.pullRequest = nil
    fixture.store.runPull(pullRequest, policy: .merge)

    #expect(fixture.store.isBusy)
    #expect(fixture.store.canInspectRepository && fixture.store.canBrowseHistory)
    #expect(!fixture.store.canUseRepository && !fixture.store.canIntegrate && !fixture.store.canCommit)

    fixture.store.navigate(.history)
    #expect(fixture.store.destination == .history)
    try await waitUntilReady { !fixture.store.visibleCommits.isEmpty }
    let commit = try #require(fixture.store.visibleCommits.first)
    fixture.store.selectCommit(commit)
    #expect(fixture.store.selectedCommit?.hash == commit.hash)
    fixture.store.loadMoreHistory()
    #expect(fixture.store.historyOptions.limit == 1000)

    fixture.store.navigate(.reference("refs/heads/feature"))
    #expect(fixture.store.destination == .reference("refs/heads/feature"))
    fixture.store.navigate(.stashes)
    #expect(fixture.store.destination == .stashes)
    fixture.store.navigate(.worktrees)
    #expect(fixture.store.destination == .worktrees)
    fixture.store.navigate(.submodules)
    #expect(fixture.store.destination == .submodules)
    fixture.store.navigate(.reflog)
    #expect(fixture.store.destination == .reflog)
    fixture.store.navigate(.branchesReview)
    #expect(fixture.store.destination == .branchesReview)
    fixture.store.navigate(.repositorySettings)
    #expect(fixture.store.showingRepositorySettings && fixture.store.canGoBack)
    fixture.store.finishRepositorySettings()
    #expect(!fixture.store.showingRepositorySettings)
    fixture.store.navigate(.workingCopy)
    #expect(fixture.store.destination == .workingCopy)

    fixture.store.commitSubject = "Draft while pulling"
    let featureRef = try #require(fixture.store.snapshot?.references.first { $0.fullName == "refs/heads/feature" })
    fixture.store.switchBranch(featureRef)
    #expect(try await fixture.repository.headPosition().branch == "refs/heads/main")

    try Data().write(to: pullGate)
    await fixture.store.operationTask?.value
    #expect(!fixture.store.isBusy && fixture.store.error == nil)
    #expect(fixture.store.commitSubject == "Draft while pulling")
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote.txt").path))

    _ = try await GitProcess.run(["config", "--unset", "remote.origin.uploadpack"], at: root)
    try await fixture.write("local.txt", "push me\n")
    _ = try await GitProcess.run(["add", "local.txt"], at: root)
    _ = try await GitProcess.run(["commit", "-m", "Local push commit"], at: root)
    try await fixture.sync()

    let pushGate = fixture.root.appendingPathComponent("push.gate")
    defer { try? Data().write(to: pushGate) }
    let prePush = hooks.appendingPathComponent("pre-push")
    try Data(gateScript(path: pushGate.path, execCommand: "exit 0").utf8).write(to: prePush)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prePush.path)
    _ = try await GitProcess.run(["config", "core.hooksPath", hooks.path], at: root)

    fixture.store.sync(.push)
    #expect(fixture.store.isBusy && fixture.store.canInspectRepository && !fixture.store.canUseRepository)
    fixture.store.navigate(.history)
    #expect(fixture.store.destination == .history)
    fixture.store.navigate(.reference("refs/heads/feature"))
    #expect(fixture.store.destination == .reference("refs/heads/feature"))

    try Data().write(to: pushGate)
    await fixture.store.operationTask?.value
    #expect(!fixture.store.isBusy && fixture.store.error == nil)
    #expect(try await GitProcess.run(["rev-parse", "refs/heads/main"], at: remote).text == GitProcess.run(["rev-parse", "HEAD"], at: root).text)
}

@Test @MainActor func slowCommitAllowsBrowsingAndPreservesNewDraftEdits() async throws {
    let fixture = try await WorkingAppFixture.make()
    defer { fixture.clean() }
    let root = await fixture.repository.root
    let hooks = fixture.root.appendingPathComponent("hooks", isDirectory: true)
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    let commitGate = fixture.root.appendingPathComponent("commit.gate")
    defer { try? Data().write(to: commitGate) }
    let preCommit = hooks.appendingPathComponent("pre-commit")
    try Data(gateScript(path: commitGate.path, execCommand: "exit 0").utf8).write(to: preCommit)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: preCommit.path)
    _ = try await GitProcess.run(["config", "core.hooksPath", hooks.path], at: root)

    try await fixture.write("a.txt", "staged work\n")
    _ = try await GitProcess.run(["add", "a.txt"], at: root)
    try await fixture.sync()

    fixture.store.commitSubject = "Initial submitted commit"
    fixture.store.commit()
    #expect(fixture.store.isBusy)

    fixture.store.navigate(.history)
    #expect(fixture.store.destination == .history)
    fixture.store.commitSubject = "Draft for next commit"

    try Data().write(to: commitGate)
    await fixture.store.operationTask?.value
    #expect(!fixture.store.isBusy && fixture.store.error == nil)
    #expect(fixture.store.commitSubject == "Draft for next commit")
    let headSubject = try await GitProcess.run(["log", "-1", "--format=%s"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(headSubject == "Initial submitted commit")
}

@Test @MainActor func toolbarSearchSupportsReadOnlyNavigationWhileBusyAndBlocksMutations() async throws {
    let fixture = try await WorkingAppFixture.make()
    defer { fixture.clean() }
    let root = await fixture.repository.root
    _ = try await GitProcess.run(["branch", "inspect-branch"], at: root)
    try await fixture.sync()

    fixture.store.isBusy = true
    defer { fixture.store.isBusy = false }

    let session = ToolbarSearchSession(store: fixture.store)
    defer { session.stop() }
    session.beginEditing()
    session.updateText("inspect-branch")
    try await waitUntilReady { session.results.contains { $0.id == "ref:refs/heads/inspect-branch" } }
    let previewItem = try #require(session.results.first { $0.id == "ref:refs/heads/inspect-branch" })
    #expect(session.submit(previewItem))
    await session.executionTask?.value
    #expect(fixture.store.destination == .reference("refs/heads/inspect-branch"))

    session.beginActions()
    session.updateText("> Create Branch")
    try await waitUntilReady { session.results.contains { $0.id == "command:Create Branch" } }
    let createBranch = try #require(session.results.first { $0.id == "command:Create Branch" })
    #expect(!session.submit(createBranch))
    #expect(!fixture.store.showingBranchSheet)
}

@Test @MainActor func sidebarAndHistoryTableStayEnabledInAppKitWhileBusyWithoutActivatingWindows() async throws {
    let fixture = try await WorkingAppFixture.make()
    defer { fixture.clean() }
    fixture.store.navigate(.history)
    try await waitUntilReady { !fixture.store.visibleCommits.isEmpty }
    fixture.store.isBusy = true
    defer { fixture.store.isBusy = false }

    let sidebarWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    sidebarWindow.isReleasedWhenClosed = false
    defer { sidebarWindow.close() }
    let sidebarHost = NSHostingView(rootView: SidebarView(store: fixture.store))
    sidebarWindow.contentView = sidebarHost
    sidebarHost.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(80))
    let outlineView = try #require(findSubview(of: NSOutlineView.self, in: sidebarHost))
    #expect(outlineView.isEnabled)

    let historyWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 520, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    historyWindow.isReleasedWhenClosed = false
    defer { historyWindow.close() }
    let historyHost = NSHostingView(rootView: HistoryView(store: fixture.store))
    historyWindow.contentView = historyHost
    historyHost.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(80))
    let tableView = try #require(findSubview(of: NSTableView.self, in: historyHost))
    let commitRow = (0..<tableView.numberOfRows).first { tableView.delegate?.tableView?(tableView, isGroupRow: $0) != true }
    let row = try #require(commitRow)
    #expect(tableView.delegate?.tableView?(tableView, shouldSelectRow: row) == true)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
