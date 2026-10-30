import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@MainActor private struct WorktreeIdentityFixture {
    let base: WorkingAppFixture
    let entries: [ManagedWorktree]
    static func make() async throws -> Self {
        let base = try await WorkingAppFixture.make()
        for (folder, branch) in [("ui", "feature/ui"), ("docs", "feature/docs"), ("detached-a", ""), ("detached-b", "")] {
            let parent = base.root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let plan = try await base.repository.previewWorktreeCreation(destination: parent.appendingPathComponent("Repo"), mode: branch.isEmpty ? .detached : .new, branch: branch)
            _ = try await base.repository.createWorktree(plan)
        }
        await base.store.loadRelatedRepositories()
        return Self(base: base, entries: base.store.worktrees)
    }
    var ui: ManagedWorktree { entries.first { $0.branch == "refs/heads/feature/ui" }! }
    func clean() { base.clean() }
}

@Test @MainActor func worktreeNamesDistinguishMatchingDirectoriesAndDetachedHeads() async throws {
    let f = try await WorktreeIdentityFixture.make(); defer { f.clean() }
    #expect(Set(f.entries.map(\.name)) == ["Repo"])
    let display = f.base.store.worktreePresentation
    let titles = f.entries.map { f.base.store.worktreeTitle($0) }
    #expect(Set(titles).count == f.entries.count)
    #expect(f.base.store.worktreeTitle(f.ui) == "feature/ui")
    let detached = f.entries.filter { !$0.isMain && $0.branch == nil }
    #expect(detached.count == 2)
    #expect(Set(detached.map { display.location(for: $0) }) == ["detached-a/Repo", "detached-b/Repo"])
    #expect(detached.allSatisfy { display.title(for: $0).contains(display.location(for: $0)) })
    let actions = f.base.store.quickActionItems(files: []).filter { $0.id.hasPrefix("worktree:") }
    #expect(Set(actions.map(\.title)).count == f.entries.count)
    // A same-named parent needs an additional component, not an arbitrary numeric suffix.
    let moved = f.base.root.appendingPathComponent("nested/detached-a")
    try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
    _ = try await f.base.repository.createWorktree(f.base.repository.previewWorktreeCreation(destination: moved.appendingPathComponent("Repo"), mode: .detached))
    await f.base.store.loadRelatedRepositories()
    let nested = f.base.store.worktrees.filter { $0.path.hasSuffix("/detached-a/Repo") }
    #expect(nested.count == 2)
    #expect(Set(nested.map { f.base.store.worktreePresentation.location(for: $0) }).count == 2)
}

@Test @MainActor func worktreeSidebarSelectionPreviewsBeforeActivationAndReturningClearsIdentity() async throws {
    let f = try await WorktreeIdentityFixture.make(); defer { f.clean() }
    let store = f.base.store, original = try #require(store.snapshot?.root)
    let token = store.repositoryToken
    store.commitSubject = "Main work stays here"
    try await f.base.write("a.txt", "main work\n"); try await f.base.sync()
    store.navigate(.worktree(f.ui.path))
    #expect(store.repositoryToken == token && store.snapshot?.root == original)
    #expect(store.selectedWorktreePaths == [f.ui.path] && WorktreesView(store: store).selected?.path == f.ui.path)
    #expect(store.operationTask == nil)
    store.activateSidebarSelection([.worktree(f.ui.path)]); await store.operationTask?.value
    #expect(store.snapshot?.root.path == f.ui.path && store.isLinkedWorktree)
    #expect(store.repositoryDisplayName == "Repo")
    #expect(store.repositoryWindowTitle.contains("feature/ui") && store.repositoryWindowTitle.contains(String(localized: "Worktree")))
    let unchanged = try String(contentsOf: original.appendingPathComponent("a.txt"), encoding: .utf8)
    #expect(unchanged == "main work\n" && store.changes.isEmpty)
    let main = try #require(store.worktrees.first { $0.isMain })
    store.openWorktree(main); await store.operationTask?.value
    #expect(store.snapshot?.root == original && !store.isLinkedWorktree)
    #expect(store.repositoryWindowTitle == "Repo")
}

@Test @MainActor func worktreeNewTabKeepsSourceContextAndNativeTitlesTrackCurrentBranch() async throws {
    let f = try await WorktreeIdentityFixture.make(); defer { f.clean() }
    let workspace = RepositoryWorkspace(library: f.base.store.library, draftsFile: f.base.root.appendingPathComponent("identity-drafts.json"))
    defer { workspace.shutdown() }
    await workspace.open(await f.base.repository.root)
    let source = workspace.activeTab
    source.store.commitSubject = "Keep main draft"
    let windows = NativeRepositoryWindows(workspace: workspace, permitsPresentation: false)
    windows.start(); defer { windows.stop() }
    source.store.openWorktree(f.ui, inNewTab: true); await source.store.operationTask?.value
    let linked = workspace.activeTab
    #expect(workspace.tabs.count == 2 && linked.id != source.id)
    #expect(source.store.commitSubject == "Keep main draft" && !source.store.isLinkedWorktree)
    #expect(linked.store.isLinkedWorktree && linked.root?.path == f.ui.path)
    let window = try #require(windows.window(for: linked.id))
    windows.updateDescriptor(linked.id)
    #expect(window.title == linked.title && window.title.contains("feature/ui"))
    #expect(window.tab.toolTip == f.ui.path)
    // Branch display must use the new snapshot even before lazy worktree metadata catches up.
    _ = try await GitProcess.run(["switch", "-c", "feature/updated"], at: URL(fileURLWithPath: f.ui.path))
    linked.store.snapshot = try await linked.store.repository?.snapshot()
    windows.updateDescriptor(linked.id)
    #expect(linked.title.contains("feature/updated") && !linked.title.contains("feature/ui"))
    #expect(window.tab.title == linked.title)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_CAPTURE_WORKTREE_IDENTITY"] == "1", "Explicit offscreen worktree identity captures."))
@MainActor func captureWorktreeIdentityWithoutPresentingWindows() async throws {
    let f = try await WorktreeIdentityFixture.make(); defer { f.clean() }
    let store = f.base.store
    store.openWorktree(f.ui); await store.operationTask?.value
    store.navigate(.worktree(f.ui.path))
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_WORKTREE_IDENTITY_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    let defaults = try #require(UserDefaults(suiteName: "GitPico-worktree-capture-" + UUID().uuidString))
    defaults.register(defaults: ["sidebar.relatedExpanded": true, "sidebar.branchesExpanded": true])
    window.styleMask = [.borderless]
    window.setFrame(NSRect(x: -10000, y: -10000, width: 1420, height: 900), display: false)
    defer { window.contentView = nil; window.close() }
    for dark in [false, true] {
        let root = HStack(spacing: 0) {
            SidebarView(store: store).frame(width: 300)
            Divider()
            VStack(spacing: 0) { WorktreesView(store: store); RepositoryStatusBar(store: store) }
        }.defaultAppStorage(defaults).frame(width: 1420, height: 900).background(Color(nsColor: .windowBackgroundColor))
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: root); window.contentView = host
        try await Task.sleep(for: .milliseconds(400)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(dark ? "worktree-dark.png" : "worktree-light.png"))
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.arguments.contains("--background-testing"), "Native Xcode app host is required for AppKit mouse tracking."))
@MainActor func worktreeSidebarNativeDoubleClickOpensPreviewedTree() async throws {
    let f = try await WorktreeIdentityFixture.make(); defer { f.clean() }
    let store = f.base.store, oldRoot = store.snapshot?.root
    store.navigate(.worktree(f.ui.path))
    let defaults = try #require(UserDefaults(suiteName: "GitPico-worktree-click-" + UUID().uuidString))
    defaults.register(defaults: ["sidebar.relatedExpanded": true])
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.styleMask = [.borderless]
    window.setFrame(NSRect(x: -10000, y: -10000, width: 320, height: 1100), display: false)
    window.contentView = NSHostingView(rootView: SidebarView(store: store).defaultAppStorage(defaults).frame(width: 320, height: 1100))
    defer { window.contentView = nil; window.close() }
    func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findTable($0) }.first
    }
    let deadline = ContinuousClock.now + .seconds(5)
    var candidate: NSTableView?
    while ContinuousClock.now < deadline {
        window.contentView?.layoutSubtreeIfNeeded()
        candidate = window.contentView.flatMap { findTable($0) }
        if (candidate?.selectedRow ?? -1) >= 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let table = try #require(candidate)
    #expect(table.doubleAction != nil && table.selectedRow >= 0)
    #expect(store.snapshot?.root == oldRoot && store.operationTask == nil)
    let rect = table.rect(ofRow: table.selectedRow)
    let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    let timestamp = ProcessInfo.processInfo.systemUptime
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
    let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.01,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 2, pressure: 0))
    NSApp.postEvent(up, atStart: true); table.mouseDown(with: down)
    try await Task.sleep(for: .milliseconds(50)); await store.operationTask?.value
    #expect(store.snapshot?.root.path == f.ui.path && store.isLinkedWorktree)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
