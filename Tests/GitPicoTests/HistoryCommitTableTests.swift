import AppKit
import Foundation
import GitCore
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
    func update(grouped: Bool = true, compact: Bool = false, reveal: HistoryReveal? = nil) {
        coordinator.update(HistoryCommitTable(store: f.store, presentation: f.store.historyPresentation, grouped: grouped, compact: compact, showGraph: true, canModifyHistory: f.store.canIntegrate, selection: f.store.selectedCommit?.hash, reveal: reveal))
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
    update(reveal: HistoryReveal(hash: far.hash, atTop: false))
    #expect(scroll.contentView.bounds.intersects(table.rect(ofRow: 26)))
    update(grouped: false, compact: true)
    #expect(table.numberOfRows == f.store.visibleCommits.count)
    #expect(table.rect(ofRow: 4).height == 32)
    #expect(f.store.selectedCommit?.hash == selection && table.selectedRow == 4)
    f.store.isBusy = true
    #expect(!coordinator.tableView(table, shouldSelectRow: 6))
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
