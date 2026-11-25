import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test @MainActor func sidebarSectionsAlwaysShowDisclosureControlsAndIndentNestedBranchesCleanly() async throws {
    let fixture = try await WorkingAppFixture.make(); defer { fixture.clean() }
    let root = await fixture.repository.root
    for name in [
        "backup/pre-merge-2026-08-27",
        "claude/animated-cloud-background-39dab7",
        "claude/button-style-adjustment-e90f2a",
        "claude/cleanup-unused-worktrees-22f023",
        "codex/sidebar-polish"
    ] {
        _ = try await GitProcess.run(["branch", name], at: root)
    }
    let remote = fixture.root.appendingPathComponent("Remote.git")
    _ = try await GitProcess.run(["clone", "--bare", root.path, remote.path], at: fixture.root)
    _ = try await GitProcess.run(["remote", "add", "origin", remote.path], at: root)
    _ = try await GitProcess.run(["fetch", "origin"], at: root)
    try await fixture.sync()

    let workspace = RepositoryWorkspace(library: fixture.store.library)
    await workspace.open(root)
    let windows = NativeRepositoryWindows(workspace: workspace, permitsPresentation: false)
    windows.start()
    defer { windows.stop(); workspace.shutdown() }
    let window = try #require(windows.window(for: workspace.selectedID))
    window.setFrame(NSRect(x: -10000, y: -10000, width: 1200, height: 860), display: false)
    window.appearance = NSAppearance(named: .aqua)
    let content = try #require(window.contentView)

    func findOutline(_ view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView, outline.convert(outline.bounds, to: nil).minX < 1 { return outline }
        return view.subviews.lazy.compactMap { findOutline($0) }.first
    }
    func expandAllDisclosures(in outline: NSOutlineView) async throws {
        for _ in 0..<4 {
            var clicked = false
            for row in 0..<outline.numberOfRows {
                guard let item = outline.item(atRow: row), outline.isExpandable(item), !outline.isItemExpanded(item),
                      !(outline.delegate?.outlineView?(outline, isGroupItem: item) ?? false),
                      let rowView = outline.rowView(atRow: row, makeIfNecessary: false),
                      let button = rowView.subviews.first(where: { $0 is NSButton }) as? NSButton else { continue }
                button.performClick(nil)
                clicked = true
                break
            }
            if !clicked { break }
            try await Task.sleep(for: .milliseconds(120))
            outline.superview?.layoutSubtreeIfNeeded()
        }
    }

    for _ in 0..<80 {
        content.layoutSubtreeIfNeeded()
        if let outline = findOutline(content), outline.numberOfRows >= 10 { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    let outline = try #require(findOutline(content))
    try await expandAllDisclosures(in: outline)
    content.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    content.layoutSubtreeIfNeeded()

    var groupRowCount = 0
    var levelOneMinX: CGFloat?
    var levelTwoMinX: CGFloat?
    for row in 0..<outline.numberOfRows {
        let item = outline.item(atRow: row)
        let level = outline.level(forRow: row)
        let isGroup = item.map { outline.delegate?.outlineView?(outline, isGroupItem: $0) ?? false } ?? false
        let rowView = outline.rowView(atRow: row, makeIfNecessary: false)
        let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false)
        if isGroup {
            groupRowCount += 1
            let hiddenHoverButtons = (rowView?.subviews ?? []).filter { ($0 as? NSButton)?.isHidden == true }
            #expect(hiddenHoverButtons.isEmpty)
        } else if let frame = cell?.frame {
            if level == 1, levelOneMinX == nil { levelOneMinX = frame.minX }
            if level == 2, levelTwoMinX == nil { levelTwoMinX = frame.minX }
        }
    }
    #expect(groupRowCount >= 5)
    let firstIndent = try #require(levelOneMinX)
    let nestedIndent = try #require(levelTwoMinX)
    #expect(nestedIndent > firstIndent && abs((nestedIndent - firstIndent) - outline.indentationPerLevel) < 1)

    let defaultsName = "GitPico-sidebar-outline-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    defaults.set(true, forKey: "sidebar.branchesExpanded")
    defaults.set(true, forKey: "sidebar.remotesExpanded")
    defaults.set(true, forKey: "sidebar.tagsExpanded")
    defaults.set(true, forKey: "sidebar.relatedExpanded")
    defaults.set(true, forKey: "sidebar.toolsExpanded")

    func render(_ name: String?, dark: Bool, expandFolders: Bool = true) async throws -> Int {
        let sidebarHost = NSHostingView(rootView: SidebarView(store: workspace.activeStore).defaultAppStorage(defaults).frame(width: 278, height: 860).background(Color(nsColor: .windowBackgroundColor)))
        let panel = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 278, height: 860), styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        panel.contentView = sidebarHost
        defer { panel.contentView = nil; panel.close() }
        var capturedOutline: NSOutlineView?
        for _ in 0..<80 {
            sidebarHost.layoutSubtreeIfNeeded()
            if let panelOutline = findOutline(sidebarHost), panelOutline.numberOfRows >= 8 {
                capturedOutline = panelOutline
                if expandFolders { try await expandAllDisclosures(in: panelOutline) }
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(200))
        sidebarHost.layoutSubtreeIfNeeded()
        if let name, let path = ProcessInfo.processInfo.environment["GITPICO_SIDEBAR_OUTLINE_CAPTURE"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = try #require(sidebarHost.bitmapImageRepForCachingDisplay(in: sidebarHost.bounds))
            sidebarHost.cacheDisplay(in: sidebarHost.bounds, to: image)
            try #require(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
        }
        return capturedOutline?.numberOfRows ?? 0
    }

    let expandedRows = try await render("sidebar-expanded-light", dark: false)
    _ = try await render("sidebar-expanded-dark", dark: true)
    defaults.set(false, forKey: "sidebar.remotesExpanded")
    defaults.set(false, forKey: "sidebar.tagsExpanded")
    let collapsedRows = try await render("sidebar-collapsed-sections", dark: false, expandFolders: false)
    #expect(collapsedRows < expandedRows && collapsedRows >= 10)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
