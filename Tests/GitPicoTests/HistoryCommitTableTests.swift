import AppKit
import Foundation
import GitCore
import Testing
import UniformTypeIdentifiers
@testable import GitPico

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
