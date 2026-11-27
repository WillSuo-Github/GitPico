import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import GitPico

@Test @MainActor func historyTableTextRemainsVisibleAfterScrollingResizingAndSelection() async throws {
    let f = try await PreviewFixture.make(commits: 540); defer { f.clean() }
    f.store.navigate(.history); await f.store.historyTask?.value
    let coordinator = HistoryCommitTable.Coordinator()
    let scroll = coordinator.makeView()
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.appearance = NSAppearance(named: .aqua)
    window.setContentSize(NSSize(width: 380, height: 300))
    window.contentView = scroll
    defer { window.contentView = nil; window.close() }
    func update(compact: Bool = false) {
        coordinator.update(HistoryCommitTable(store: f.store, presentation: f.store.historyPresentation, grouped: false, compact: compact, showGraph: true, canModifyHistory: true, selection: f.store.selectedCommit?.hash, reveal: nil))
        scroll.layoutSubtreeIfNeeded()
    }
    update()
    let table = coordinator.table
    for width in [380.0, 260.0, 540.0, 380.0] {
        window.setContentSize(NSSize(width: width, height: 300))
        for row in [0, 100, 250, 0] where row < table.numberOfRows {
            table.scrollRowToVisible(row)
            update()
            let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
            #expect(cell.bounds.width > 200)
            let image = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
            cell.cacheDisplay(in: cell.bounds, to: image)
            #expect(historyTextPixels(image, light: false) > 30, "Missing text at row \(row), width \(width)")
        }
    }
    table.scrollRowToVisible(2)
    table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    await f.store.detailTask?.value
    update()
    let row = try #require(table.rowView(atRow: 2, makeIfNecessary: true))
    row.isEmphasized = true
    let cell = try #require(table.view(atColumn: 0, row: 2, makeIfNecessary: true) as? NSTableCellView)
    cell.backgroundStyle = .emphasized
    let image = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
    cell.cacheDisplay(in: cell.bounds, to: image)
    #expect(historyTextPixels(image, light: true) > 30, "Emphasized selection must use light text")
    func capture(_ state: String) throws {
        guard let path = ProcessInfo.processInfo.environment["GITPICO_HISTORY_TABLE_CAPTURE"] else { return }
        let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        let url = URL(fileURLWithPath: path).appendingPathComponent("history-table-\(state).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
    try capture("light-selected")
    row.isEmphasized = false
    cell.backgroundStyle = .normal
    let inactive = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
    cell.cacheDisplay(in: cell.bounds, to: inactive)
    #expect(historyTextPixels(inactive, light: false) > 30, "Inactive selection must restore dark text")
    try capture("light-inactive")
    window.appearance = NSAppearance(named: .darkAqua)
    cell.needsDisplay = true
    let dark = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
    cell.cacheDisplay(in: cell.bounds, to: dark)
    #expect(historyTextPixels(dark, light: true) > 30, "Dark appearance must retain visible text")
    try capture("dark-inactive")
    update(compact: true)
    let compactCell = try #require(table.view(atColumn: 0, row: 2, makeIfNecessary: true))
    #expect(compactCell.bounds.height == 32)
    let compactImage = try #require(compactCell.bitmapImageRepForCachingDisplay(in: compactCell.bounds))
    compactCell.cacheDisplay(in: compactCell.bounds, to: compactImage)
    #expect(historyTextPixels(compactImage, light: true) > 30, "Compact rows must retain their subject")
    try capture("dark-compact")
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

/// Count opaque glyph pixels in the text column, excluding the graph and avatar.
@MainActor private func historyTextPixels(_ image: NSBitmapImageRep, light: Bool) -> Int {
    let scale = CGFloat(image.pixelsWide) / image.size.width
    var count = 0
    for y in Int(6 * scale)..<min(image.pixelsHigh, Int(44 * scale)) {
        for x in Int(80 * scale)..<max(Int(80 * scale), image.pixelsWide - Int(15 * scale)) {
            guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
            let value = min(color.redComponent, color.greenComponent, color.blueComponent)
            if light ? value > 0.8 : max(color.redComponent, color.greenComponent, color.blueComponent) < 0.65 { count += 1 }
        }
    }
    return count
}

@Test @MainActor func historyTableKeepsSelectionRevealAndGroupingInSync() async throws {
    let f = try await PreviewFixture.make(commits: 40); defer { f.clean() }
    f.store.navigate(.reference("refs/heads/preview/branch-1"))
    await f.store.historyTask?.value; await f.store.detailTask?.value
    let coordinator = HistoryCommitTable.Coordinator()
    let scroll = coordinator.makeView()
    scroll.frame = NSRect(x: 0, y: 0, width: 380, height: 200)
    func update(grouped: Bool = true, compact: Bool = false, reveal: HistoryReveal? = nil, insets: EdgeInsets = EdgeInsets()) {
        coordinator.update(HistoryCommitTable(store: f.store, presentation: f.store.historyPresentation, grouped: grouped, compact: compact, showGraph: true, canModifyHistory: f.store.canIntegrate, selection: f.store.selectedCommit?.hash, reveal: reveal, insets: insets))
        scroll.layoutSubtreeIfNeeded()
    }
    update()
    let table = coordinator.table
    #expect(table.numberOfRows == f.store.visibleCommits.count + 1)
    #expect(table.selectedRow == 1)
    #expect(!coordinator.tableView(table, shouldSelectRow: 0))
    table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
    #expect(f.store.selectedCommit?.hash == f.store.visibleCommits[4].hash)
    await f.store.detailTask?.value
    let selection = f.store.selectedCommit?.hash
    let far = f.store.visibleCommits[25]
    let insets = EdgeInsets(top: 56, leading: 0, bottom: 32, trailing: 0)
    update(reveal: HistoryReveal(hash: far.hash, atTop: false), insets: insets)
    let clip = scroll.contentView
    let unobstructedMiddle = (clip.bounds.minY + insets.top + clip.bounds.maxY - insets.bottom) / 2
    #expect(abs(unobstructedMiddle - table.rect(ofRow: 26).midY) < 1)
    #expect(clip.bounds.height == scroll.bounds.height)
    update(reveal: HistoryReveal(hash: far.hash, atTop: true), insets: insets)
    #expect(abs(clip.bounds.minY + insets.top - table.rect(ofRow: 26).minY) < 1)
    let first = f.store.visibleCommits[0]
    update(reveal: HistoryReveal(hash: first.hash, atTop: true), insets: insets)
    #expect(clip.bounds.minY + insets.top <= table.rect(ofRow: 1).minY)
    table.scrollRowToVisible(table.numberOfRows - 1)
    #expect(clip.bounds.maxY - insets.bottom >= table.rect(ofRow: table.numberOfRows - 1).maxY - 1)
    update(grouped: false, compact: true)
    #expect(table.numberOfRows == f.store.visibleCommits.count)
    #expect(table.rect(ofRow: 4).height == 32)
    #expect(f.store.selectedCommit?.hash == selection && table.selectedRow == 4)
    f.store.isBusy = true
    #expect(coordinator.tableView(table, shouldSelectRow: 6))
    #expect(coordinator.tableView(table, pasteboardWriterForRow: 6) == nil)
    f.store.isBusy = false
    f.store.navigate(.reference("refs/heads/preview/branch-5"))
    await f.store.historyTask?.value
    update(grouped: false)
    #expect(table.selectedRow == 0 && f.store.selectedCommit?.hash == f.tips[5])
}

@Test @MainActor func historyTableDragPayloadAndContextMenuUseTheCurrentCommit() async throws {
    let f = try await PreviewFixture.make(); defer { f.clean() }
    f.store.navigate(.history); await f.store.historyTask?.value
    let coordinator = HistoryCommitTable.Coordinator()
    _ = coordinator.makeView()
    coordinator.update(HistoryCommitTable(store: f.store, presentation: f.store.historyPresentation, grouped: false, compact: false, showGraph: true, canModifyHistory: true, selection: f.store.selectedCommit?.hash, reveal: nil))
    let item = try #require(coordinator.tableView(coordinator.table, pasteboardWriterForRow: 3) as? NSPasteboardItem)
    let data = try #require(item.data(forType: NSPasteboard.PasteboardType(UTType.picoDrag.identifier)))
    let token = try JSONDecoder().decode(PicoDragToken.self, from: data)
    guard case .commit(let commit) = f.store.dragAction(token) else { Issue.record("Missing native history drag action"); return }
    #expect(commit.hash == f.store.visibleCommits[3].hash)
    #expect(coordinator.table.rowMenu?(-1) == nil)
    #expect(coordinator.table.rowMenu?(3) != nil)
    f.store.isBusy = true
    #expect(coordinator.tableView(coordinator.table, pasteboardWriterForRow: 3) == nil)
    f.store.isBusy = false
}

@MainActor private func findHistoryScrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView, scroll.documentView is HistoryTableView { return scroll }
    for subview in view.subviews {
        if let found = findHistoryScrollView(in: subview) { return found }
    }
    return nil
}

@Test @MainActor func branchSwitchesPreserveTopAndScrolledHistoryPositionsAndShowFirstMonthHeader() async throws {
    let fixture = try await PreviewFixture.make(commits: 60, branches: 12); defer { fixture.clean() }
    let previousGroups = AppPreferences.shared.historyGroups
    AppPreferences.shared.historyGroups = true
    defer { AppPreferences.shared.historyGroups = previousGroups }

    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 720, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: RepositoryDetailView(store: fixture.store))
    window.contentView = host
    defer { window.contentView = nil; window.close() }

    func settleHistory() async throws -> (NSScrollView, HistoryTableView) {
        await fixture.store.historyTask?.value
        await fixture.store.detailTask?.value
        for _ in 0..<16 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let scroll = try #require(findHistoryScrollView(in: host))
        let table = try #require(scroll.documentView as? HistoryTableView)
        return (scroll, table)
    }

    func offsetFromTop(_ scroll: NSScrollView) -> CGFloat {
        scroll.contentView.bounds.minY + scroll.contentView.contentInsets.top
    }

    func scroll(toOffset offset: CGFloat, in scroll: NSScrollView) async throws {
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y = offset - clip.contentInsets.top
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    // First visit to Branch 1 starts at exact top (offset 0, showing the first month header).
    fixture.store.navigate(.reference("refs/heads/preview/branch-1"))
    let (scroll1, table1) = try await settleHistory()
    #expect(abs(offsetFromTop(scroll1)) < 1)
    #expect(table1.selectedRow == 1)

    // Select a much lower commit on Branch 1, then scroll back to the very top.
    table1.selectRowIndexes(IndexSet(integer: 25), byExtendingSelection: false)
    _ = try await settleHistory()
    let selectedOnBranch1 = try #require(fixture.store.selectedCommit?.hash)
    try await scroll(toOffset: 0, in: scroll1)
    #expect(abs(offsetFromTop(scroll1)) < 1)

    // Visit Branch 9 (first visit defaults to exact top), then return to Branch 1:
    // Branch 1 must stay at the very top while keeping its selected commit.
    fixture.store.navigate(.reference("refs/heads/preview/branch-9"))
    let (scroll9, _) = try await settleHistory()
    #expect(abs(offsetFromTop(scroll9)) < 1)

    fixture.store.navigate(.reference("refs/heads/preview/branch-1"))
    let (scroll1Back, table1Back) = try await settleHistory()
    #expect(fixture.store.selectedCommit?.hash == selectedOnBranch1)
    #expect(table1Back.selectedRow == 25)
    #expect(abs(offsetFromTop(scroll1Back)) < 1)

    // Scroll Branch 9 down without changing selection, switch away, then return to Branch 9.
    fixture.store.navigate(.reference("refs/heads/preview/branch-9"))
    let (scroll9Again, _) = try await settleHistory()
    try await scroll(toOffset: 520, in: scroll9Again)
    #expect(abs(offsetFromTop(scroll9Again) - 520) < 1)

    // Rapidly switch Branch 9 (520) -> Branch 1 (cached at 0) -> Branch 5 before SwiftUI renders Branch 1.
    fixture.store.navigate(.reference("refs/heads/preview/branch-1"))
    fixture.store.navigate(.reference("refs/heads/preview/branch-5"))
    let (scroll5, _) = try await settleHistory()
    #expect(abs(offsetFromTop(scroll5)) < 1)

    // Returning to Branch 1 must not inherit Branch 9's 520 offset.
    fixture.store.navigate(.reference("refs/heads/preview/branch-1"))
    let (scroll1AfterRapid, _) = try await settleHistory()
    #expect(abs(offsetFromTop(scroll1AfterRapid)) < 1)

    // Returning to Branch 9 restores its scrolled offset, including across Working Copy view teardown.
    fixture.store.navigate(.reference("refs/heads/preview/branch-9"))
    let (scroll9Restored, _) = try await settleHistory()
    #expect(abs(offsetFromTop(scroll9Restored) - 520) < 1)

    fixture.store.navigate(.workingCopy)
    for _ in 0..<8 {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(15))
    }
    fixture.store.navigate(.reference("refs/heads/preview/branch-1"))
    let (scroll1AfterWorkingCopy, _) = try await settleHistory()
    #expect(abs(offsetFromTop(scroll1AfterWorkingCopy)) < 1)

    fixture.store.navigate(.reference("refs/heads/preview/branch-9"))
    let (scroll9AfterWorkingCopy, _) = try await settleHistory()
    #expect(abs(offsetFromTop(scroll9AfterWorkingCopy) - 520) < 1)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test func legacyNavigationBookmarkDecodesWithoutScrollOffset() throws {
    let legacyJSON = #"{"search":"fix","options":{"limit":500,"query":"fix","firstParent":false,"sortByDate":false},"commitHash":"abc123"}"#
    let decoded = try JSONDecoder().decode(NavigationBookmark.self, from: Data(legacyJSON.utf8))
    #expect(decoded.search == "fix")
    #expect(decoded.commitHash == "abc123")
    #expect(decoded.scrollOffset == nil)
}
