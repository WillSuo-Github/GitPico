import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test @MainActor func visibleBulkStagingNeverIncludesHiddenFilesEvenBeforeListRefresh() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    for name in ["a.txt", "b.txt", "c.txt"] { try await f.write(name, "changed\n") }
    try await f.sync()
    f.store.search = "a.txt"
    f.store.stageVisibleFiles(); await f.finish()
    #expect(f.store.staged.map(\.path) == ["a.txt"])
    f.store.search = "b.txt"
    f.store.unstageVisibleFiles(); await f.finish()
    #expect(f.store.staged.map(\.path) == ["a.txt"])
    f.store.stageVisibleFiles(); await f.finish()
    #expect(Set(f.store.staged.map(\.path)) == ["a.txt", "b.txt"])
    f.store.search = "a.txt"
    f.store.unstageVisibleFiles(); await f.finish()
    #expect(f.store.staged.map(\.path) == ["b.txt"])
}

@Test @MainActor func nativeHistoryMultipleSelectionPersistsThroughRefreshAndPreparesBatchInOrder() async throws {
    let f = try await PreviewFixture.make(commits: 4, branches: 1); defer { f.clean() }
    f.store.navigate(.history); await f.store.historyTask?.value
    let coordinator = HistoryCommitTable.Coordinator()
    let scroll = coordinator.makeView()
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.setContentSize(NSSize(width: 500, height: 400)); window.contentView = scroll
    defer { window.contentView = nil; window.close() }
    func update() {
        coordinator.update(HistoryCommitTable(store: f.store, presentation: f.store.historyPresentation, grouped: false, compact: false, showGraph: true, canModifyHistory: true, selection: f.store.selectedCommit?.hash, reveal: nil))
    }
    update()
    coordinator.table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
    let hashes = f.store.visibleCommits.prefix(2).map(\.hash)
    #expect(f.store.selectedHistoryHashes == Set(hashes))
    update()
    #expect(coordinator.table.selectedRowIndexes == IndexSet([0, 1]))
    f.store.requestHistory(); await f.store.historyTask?.value; update()
    #expect(coordinator.table.selectedRowIndexes == IndexSet([0, 1]))
    f.store.reviewSelectedCommits(.cherryPick)
    #expect(f.store.batchIntegrationRequest?.commits.map(\.hash) == hashes.reversed())
    f.store.reviewSelectedCommits(.revert)
    #expect(f.store.batchIntegrationRequest?.commits.map(\.hash) == hashes)
    coordinator.table.deselectAll(nil); update()
    #expect(f.store.selectedHistoryHashes.isEmpty && f.store.selectedCommit == nil)
    #expect(coordinator.table.selectedRowIndexes.isEmpty)
    coordinator.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false); update()
    #expect(f.store.selectedHistoryHashes == [hashes[1]])
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func conflictEditorRevealsWithoutSelectingWholeBlockAndPropagatesEdits() async throws {
    let draft = EditorDraft()
    let host = NSHostingView(rootView: ConflictResultEditor(text: Binding(get: { draft.text }, set: { draft.text = $0 }), reveal: "conflict", focusRequest: UUID()))
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.setContentSize(NSSize(width: 700, height: 400)); window.contentView = host
    defer { window.contentView = nil; window.close() }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
    func editor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }
    let text = try #require(editor(in: host))
    #expect(text.string == draft.text && text.bounds.width > 0 && text.bounds.height > 0)
    #expect(text.selectedRange() == NSRange(location: 7, length: 0))
    text.insertText("edited", replacementRange: NSRange(location: 7, length: 8))
    #expect(draft.text == "before\nedited\nafter\n")
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@MainActor private final class EditorDraft { var text = "before\nconflict\nafter\n" }

@Test func structuredHistoryFiltersPreserveLiteralQuotesAndPaths() throws {
    let text = HistorySearchFilters.query(existing: "fix", author: "A \"Name\"", path: "Sources/a[b].swift", content: "hello \"world\"", after: "2026-01-01", before: "")
    let parsed = try HistoryQuery(text)
    #expect(parsed.paths == ["Sources/a[b].swift"])
    #expect(parsed.arguments.contains("--author=A \"Name\""))
    #expect(parsed.arguments.contains("-Shello \"world\""))
}
