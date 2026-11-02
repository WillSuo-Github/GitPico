import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@MainActor private func sidebarCheckoutFixture() async throws -> (WorkingAppFixture, Reference) {
    let f = try await WorkingAppFixture.make()
    _ = try await GitProcess.run(["branch", "topic"], at: f.repository.root)
    try await f.sync()
    return (f, try #require(f.store.snapshot?.references.first { $0.fullName == "refs/heads/topic" }))
}

@Test(.enabled(if: ProcessInfo.processInfo.arguments.contains("--background-testing"), "Native Xcode app host is required for AppKit mouse tracking."), arguments: [false, true])
@MainActor func sidebarNativeDoubleActionChecksOutBranchWithoutChangingSingleSelectionBehavior(remote: Bool) async throws {
    let (f, local) = try await sidebarCheckoutFixture(); defer { f.clean() }
    var target = local
    if remote {
        _ = try await GitProcess.run(["remote", "add", "origin", f.root.path], at: f.repository.root)
        _ = try await GitProcess.run(["update-ref", "refs/remotes/origin/remote-topic", local.hash], at: f.repository.root)
        try await f.sync()
        target = try #require(f.store.snapshot?.references.first { $0.fullName == "refs/remotes/origin/remote-topic" })
    }
    let expectedHead = remote ? "refs/heads/remote-topic" : target.fullName
    f.store.navigate(.reference(target.fullName))
    await f.store.historyTask?.value; await f.store.detailTask?.value
    let defaultsName = "GitPico-sidebar-checkout-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defaults.set(true, forKey: "sidebar.branchesExpanded")
    defaults.set(true, forKey: "sidebar.remotesExpanded")
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.styleMask = [.borderless]
    window.setFrame(NSRect(x: -10000, y: -10000, width: 340, height: 900), display: false)
    window.contentView = NSHostingView(rootView: SidebarView(store: f.store).defaultAppStorage(defaults).frame(width: 340, height: 900))
    defer { window.contentView = nil; window.close() }
    func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findTable($0) }.first
    }
    window.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    let deadline = ContinuousClock.now + .seconds(5)
    var nativeTable: NSTableView?
    var expandedRemoteRows = false
    while ContinuousClock.now < deadline {
        window.contentView?.layoutSubtreeIfNeeded()
        nativeTable = window.contentView.flatMap { findTable($0) }
        if remote, !expandedRemoteRows, let table = nativeTable, table.numberOfRows > 5 {
            let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
            var row = 0
            while row < table.numberOfRows {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.keyDown(with: right)
                try await Task.sleep(for: .milliseconds(20))
                window.contentView?.layoutSubtreeIfNeeded()
                row += 1
            }
            expandedRemoteRows = true
            f.store.navigate(.reference(target.fullName))
            try await Task.sleep(for: .milliseconds(50))
            continue
        }
        if (nativeTable?.selectedRow ?? -1) >= 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let table = try #require(nativeTable)
    #expect(table.doubleAction != nil)
    #expect(table.selectedRow >= 0)
    #expect(try await f.repository.headPosition().branch == "refs/heads/main")
    #expect(f.store.operationTask == nil && f.store.automaticStashRequest == nil)
    let row = table.rect(ofRow: table.selectedRow)
    let point = table.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
    let timestamp = ProcessInfo.processInfo.systemUptime
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
    let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.01,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 2, pressure: 0))
    NSApp.postEvent(up, atStart: true)
    table.mouseDown(with: down)
    try await Task.sleep(for: .milliseconds(50))
    await f.finish()
    #expect(try await f.repository.headPosition().branch == expectedHead)
    #expect(f.store.snapshot?.references.first(where: \.isCurrent)?.fullName == expectedHead)
    if remote { #expect(f.store.snapshot?.references.first(where: \.isCurrent)?.upstream == target.name) }
    #expect(f.store.error == nil && !f.store.isBusy)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func sidebarBranchActivationReviewsEveryKindOfLocalChangeAndCancelKeepsWork() async throws {
    let (f, target) = try await sidebarCheckoutFixture(); defer { f.clean() }
    try await f.write("a.txt", "staged work\n")
    _ = try await GitProcess.run(["add", "a.txt"], at: f.repository.root)
    try await f.write("b.txt", "unstaged work\n")
    try await f.write("new.txt", "untracked work\n"); try await f.sync()
    let before = try await f.repository.aiCommitFingerprint(scope: .allChanges)
    f.store.activateSidebarSelection([.reference(target.fullName)])
    let request = try #require(f.store.automaticStashRequest)
    #expect(request.refresh == .workingTree)
    #expect(f.store.operationTask == nil && !f.store.isBusy)
    #expect(try await f.repository.headPosition().branch == "refs/heads/main")
    f.store.automaticStashRequest = nil
    #expect(try await f.repository.aiCommitFingerprint(scope: .allChanges) == before)
    #expect(try await f.repository.headPosition().branch == "refs/heads/main")
    #expect(f.store.snapshot?.stashes.isEmpty == true)
    // Confirming without a stash carries compatible changes using Git's normal protections.
    f.store.activateSidebarSelection([.reference(target.fullName)])
    let confirmed = try #require(f.store.automaticStashRequest)
    f.store.automaticStashRequest = nil
    f.store.perform(confirmed.title, refresh: confirmed.refresh, action: confirmed.action)
    await f.finish()
    #expect(try await f.repository.headPosition().branch == target.fullName)
    #expect(f.store.error == nil && f.store.changes.count == 3 && f.store.staged.count == 1)
    let newFile = await f.repository.root.appendingPathComponent("new.txt")
    #expect(try String(contentsOf: newFile, encoding: .utf8) == "untracked work\n")
}

@Test(arguments: ["staged", "unstaged", "untracked"])
@MainActor func sidebarBranchActivationPromptsForEachLocalChangeKind(kind: String) async throws {
    let (f, target) = try await sidebarCheckoutFixture(); defer { f.clean() }
    try await f.write(kind == "untracked" ? "new.txt" : "a.txt", "local work\n")
    if kind == "staged" { _ = try await GitProcess.run(["add", "a.txt"], at: f.repository.root) }
    try await f.sync()
    f.store.activateSidebarSelection([.reference(target.fullName)])
    #expect(f.store.automaticStashRequest != nil && f.store.operationTask == nil)
    #expect(try await f.repository.headPosition().branch == "refs/heads/main")
}

@Test @MainActor func sidebarBranchActivationIgnoresCurrentTagsAndBusySelections() async throws {
    let (f, target) = try await sidebarCheckoutFixture(); defer { f.clean() }
    _ = try await GitProcess.run(["tag", "v1"], at: f.repository.root)
    _ = try await GitProcess.run(["update-ref", "refs/remotes/origin/topic", target.hash], at: f.repository.root)
    try await f.sync()
    let selections: [Set<Destination>] = [[], [.history], [.reference("refs/heads/main")], [.reference("refs/tags/v1")], [.reference("refs/heads/missing")], [.reference(target.fullName), .history]]
    for selection in selections {
        f.store.activateSidebarSelection(selection)
        #expect(f.store.operationTask == nil && f.store.automaticStashRequest == nil)
    }
    f.store.isBusy = true
    f.store.activateSidebarSelection([.reference(target.fullName)])
    f.store.isBusy = false
    #expect(f.store.operationTask == nil && f.store.error == nil)
    #expect(try await f.repository.headPosition().branch == "refs/heads/main")
}

@Test(arguments: ["staged", "unstaged", "untracked"])
@MainActor func sidebarRemoteBranchActivationPromptsBeforeCreatingAndCancelPreservesWork(kind: String) async throws {
    let (f, local) = try await sidebarCheckoutFixture(); defer { f.clean() }
    _ = try await GitProcess.run(["remote", "add", "origin", f.root.path], at: f.repository.root)
    _ = try await GitProcess.run(["update-ref", "refs/remotes/origin/feature/remote", local.hash], at: f.repository.root)
    try await f.write(kind == "untracked" ? "new.txt" : "a.txt", "local work\n")
    if kind == "staged" { _ = try await GitProcess.run(["add", "a.txt"], at: f.repository.root) }
    try await f.sync()
    let before = try await f.repository.aiCommitFingerprint(scope: .allChanges)
    let beforeStatus = try await GitProcess.run(["status", "--porcelain=v1", "-z"], at: f.repository.root).data
    f.store.activateSidebarSelection([.reference("refs/remotes/origin/feature/remote")])
    let request = try #require(f.store.automaticStashRequest)
    #expect(f.store.operationTask == nil)
    #expect(try await f.repository.headPosition().branch == "refs/heads/main")
    #expect(try await f.repository.references().contains { $0.fullName == "refs/heads/feature/remote" } == false)
    f.store.automaticStashRequest = nil
    #expect(try await f.repository.aiCommitFingerprint(scope: .allChanges) == before)
    f.store.perform(request.title, refresh: request.refresh, action: request.action)
    await f.finish()
    #expect(f.store.error == nil)
    #expect(try await f.repository.headPosition().branch == "refs/heads/feature/remote")
    #expect(try await GitProcess.run(["status", "--porcelain=v1", "-z"], at: f.repository.root).data == beforeStatus)
    #expect(try String(contentsOf: await f.repository.root.appendingPathComponent(kind == "untracked" ? "new.txt" : "a.txt"), encoding: .utf8) == "local work\n")
}

@Test @MainActor func sidebarRemoteBranchCollisionOffersNameInsteadOfChangingExistingBranch() async throws {
    let (f, local) = try await sidebarCheckoutFixture(); defer { f.clean() }
    _ = try await GitProcess.run(["remote", "add", "origin", f.root.path], at: f.repository.root)
    _ = try await GitProcess.run(["update-ref", "refs/remotes/origin/topic", local.hash], at: f.repository.root)
    try await f.sync()
    f.store.activateSidebarSelection([.reference("refs/remotes/origin/topic")])
    await f.store.metadataTask?.value
    guard case .createBranch(let hash, let upstream) = f.store.managementRequest?.action else {
        Issue.record("Expected branch creation sheet for a name collision"); return
    }
    #expect(hash == local.hash && upstream == "refs/remotes/origin/topic")
    #expect(f.store.operationTask == nil && f.store.automaticStashRequest == nil)
    #expect(try await f.repository.headPosition().branch == "refs/heads/main")
}
