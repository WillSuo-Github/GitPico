import AppKit
import Foundation
import GitCore
import Testing
@testable import GitPico

@Test @MainActor func fetchedCommitsAppearAboveLocalHeadInNativeHistory() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let root = await f.repository.root
    let origin = f.root.appendingPathComponent("HistoryOrigin.git")
    let peer = f.root.appendingPathComponent("HistoryPeer")
    func git(_ args: [String], at location: URL) async throws {
        _ = try await GitProcess.run(args, at: location)
    }
    try await git(["init", "--bare", origin.path], at: f.root)
    try await git(["remote", "add", "origin", origin.path], at: root)
    try await git(["push", "-u", "origin", "main"], at: root)
    try await f.sync()
    let localHead = try #require(f.store.snapshot?.head.hash)
    f.store.navigate(.reference("refs/heads/main"))
    await f.store.historyTask?.value
    await f.store.detailTask?.value
    #expect(f.store.visibleCommits.first?.hash == localHead)

    let coordinator = HistoryCommitTable.Coordinator()
    let scroll = coordinator.makeView()
    let size = NSSize(width: 510, height: 330)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = scroll
    defer { window.contentView = nil; window.close() }
    func updateTable() {
        coordinator.update(HistoryCommitTable(store: f.store, presentation: f.store.historyPresentation,
            grouped: false, compact: false, showGraph: true, canModifyHistory: f.store.canIntegrate,
            selection: f.store.selectedCommit?.hash, reveal: f.store.historyReveal))
        scroll.layoutSubtreeIfNeeded()
    }
    updateTable()

    try await git(["clone", "--branch", "main", origin.path, peer.path], at: f.root)
    for (key, value) in [("user.name", "History Test"), ("user.email", "fixture@example.invalid"),
                         ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
        try await git(["config", key, value], at: peer)
    }
    for index in 1...35 {
        try await git(["commit", "--allow-empty", "-m", "Incoming commit \(index)"], at: peer)
    }
    try await git(["push", "origin", "main"], at: peer)
    f.store.sync(.fetch)
    await f.finish()
    await f.store.historyTask?.value
    await f.store.detailTask?.value
    updateTable()

    #expect(f.store.error == nil && f.store.snapshot?.behind == 35)
    #expect(f.store.snapshot?.head.hash == localHead && f.store.selectedCommit?.hash == localHead)
    #expect(f.store.visibleCommits.first?.subject == "Incoming commit 35")
    #expect(f.store.visibleCommits.prefix(35).allSatisfy { $0.subject.hasPrefix("Incoming commit ") })
    #expect(f.store.visibleCommits.dropFirst(35).first?.hash == localHead)
    #expect(scroll.contentView.bounds.minY <= 1)
    let column = try #require(coordinator.table.tableColumns.first)
    let tipCell = try #require(coordinator.tableView(coordinator.table, viewFor: column, row: 0))
    let headCell = try #require(coordinator.tableView(coordinator.table, viewFor: column, row: 35))
    let tipLabels = tipCell.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
    let headLabels = headCell.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
    #expect(tipLabels.contains("origin/main"))
    #expect(headLabels.contains("HEAD"))

    if let path = ProcessInfo.processInfo.environment["GITPICO_INCOMING_HISTORY_CAPTURE"] {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func capture(_ name: String) throws {
            let image = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: image)
            try #require(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name))
        }
        try capture("Incoming.png")
        coordinator.table.scrollRowToVisible(35)
        scroll.layoutSubtreeIfNeeded()
        try capture("Local-HEAD.png")
    }
    #expect(!window.isVisible && !NSApp.isActive)
}

@Test func headBadgeDistinguishesHeadFromOrdinaryReferenceNames() {
    #expect(CommitDecorationBadge(["origin/main", "HEAD -> main"]).label == "HEAD")
    #expect(CommitDecorationBadge(["HEAD"]).isHead)
    let other = CommitDecorationBadge(["HEADline"])
    #expect(other.label == "HEADline" && !other.isHead)
    let tag = CommitDecorationBadge(["tag: HEADline"])
    #expect(tag.label == "HEADline" && tag.isTag && !tag.isHead)
}
