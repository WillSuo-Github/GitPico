import AppKit
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test(.enabled(if: ProcessInfo.processInfo.arguments.contains("--background-testing"), "Native Xcode app host is required for AppKit mouse tracking."))
@MainActor func sidebarNativeSelectionSupportsShiftRangesAndCommandToggling() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let names = ["multi-alpha", "multi-beta", "multi-gamma", "multi-omega"]
    for name in names { _ = try await GitProcess.run(["branch", name], at: f.repository.root) }
    try await f.sync()
    f.store.sidebarFilter = "multi-"
    let defaultsName = "GitPico-sidebar-selection-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defaults.set(true, forKey: "sidebar.branchesExpanded")
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
    func settle(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "Sidebar selection did not settle")
    }
    try await settle { (window.contentView.flatMap { findTable($0) }?.selectedRow ?? -1) >= 0 }
    let table = try #require(window.contentView.flatMap { findTable($0) })
    #expect(table.allowsMultipleSelection)
    var rows: [Int] = []
    for name in names {
        let previousRow = table.selectedRow
        f.store.navigate(.reference("refs/heads/" + name))
        await f.store.historyTask?.value; await f.store.detailTask?.value
        try await settle { table.selectedRow >= 0 && table.selectedRowIndexes.count == 1 && table.selectedRow != previousRow }
        rows.append(table.selectedRow)
    }
    #expect(rows == rows.sorted())
    #expect(rows.last! - rows.first! == 3)
    func click(_ row: Int, modifiers: NSEvent.ModifierFlags = []) async throws {
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: modifiers, timestamp: timestamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: modifiers, timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        table.mouseDown(with: down)
        try await Task.sleep(for: .milliseconds(50))
        window.contentView?.layoutSubtreeIfNeeded()
    }
    try await click(rows[0])
    try await settle { f.store.destination == .reference("refs/heads/" + names[0]) }
    try await click(rows[3], modifiers: .shift)
    #expect(table.selectedRowIndexes == IndexSet(integersIn: rows[0]...rows[3]))
    #expect(f.store.destination == .reference("refs/heads/" + names[0]))
    try await click(rows[1], modifiers: .command)
    #expect(table.selectedRowIndexes == IndexSet([rows[0], rows[2], rows[3]]))
    try await click(rows[1], modifiers: .command)
    #expect(table.selectedRowIndexes == IndexSet(rows))
    // An unrelated view update must preserve the group selection.
    f.store.sidebarFilter = "multi"
    try await Task.sleep(for: .milliseconds(100))
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(table.selectedRowIndexes == IndexSet(rows))
    #expect(f.store.operationTask == nil && f.store.automaticStashRequest == nil)
    #expect(try await f.repository.headPosition().branch == "refs/heads/main")
    // Normal clicks and external navigation return to a single selection.
    try await click(rows[2])
    try await settle { f.store.destination == .reference("refs/heads/" + names[2]) }
    #expect(table.selectedRowIndexes == IndexSet(integer: rows[2]))
    f.store.navigate(.reference("refs/heads/" + names[1]))
    try await settle { table.selectedRowIndexes == IndexSet(integer: rows[1]) }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
