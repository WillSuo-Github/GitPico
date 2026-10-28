import AppKit
import SwiftUI
import Testing
@testable import GitPico

@MainActor private final class PickerReorderSession: NSDraggingSession {
    // AppKit's session getters are nonisolated; the fixture is only used on the main actor.
    nonisolated(unsafe) let board: NSPasteboard
    init(board: NSPasteboard) { self.board = board; super.init() }
    override var draggingPasteboard: NSPasteboard { board }
    override var draggingSequenceNumber: Int { 1 }
    override var draggingLocation: NSPoint { .zero }
}

@MainActor private final class PickerReorderDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let table: NSTableView
    init(table: NSTableView) { self.table = table }
    var draggingDestinationWindow: NSWindow? { table.window }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { table }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@Test @MainActor func pickerNativeListReordersAndPreservesSelectionWithoutOpeningARepository() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-picker-reorder-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: [])
    var ids: [UUID] = []
    for name in ["Alpha", "Beta", "Gamma"] { ids.append(try library.register(root.appendingPathComponent(name))) }
    let workspace = RepositoryWorkspace(library: library, draftsFile: root.appendingPathComponent("drafts.json"))
    let tab = workspace.activeTab
    tab.pickerFilter = .all; tab.pickerSelection = ids[2]
    let window = RepositoryNativeWindow(tabID: tab.id, permitsPresentation: false)
    window.contentView = NSHostingView(rootView: RepositoryPickerView(workspace: workspace, tab: tab, showsSidebar: false))
    defer { window.contentView = nil; window.close(); workspace.shutdown() }
    func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findTable($0) }.first
    }
    let deadline = ContinuousClock.now + .seconds(5)
    var nativeTable: NSTableView?
    while ContinuousClock.now < deadline {
        window.contentView?.layoutSubtreeIfNeeded()
        nativeTable = window.contentView.flatMap { findTable($0) }
        if nativeTable?.numberOfRows == 3 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let table = try #require(nativeTable as? NSOutlineView)
    try await Task.sleep(for: .milliseconds(300))
    #expect(table.numberOfRows == 3)
    let drag = PickerReorderDrag(table: table)
    defer { drag.draggingPasteboard.releaseGlobally() }
    let source = try #require(table.item(atRow: 2))
    let target = try #require(table.item(atRow: 0))
    let parent = table.parent(forItem: target), childIndex = table.childIndex(forItem: target)
    let writer = try #require(table.dataSource?.outlineView?(table, pasteboardWriterForItem: source))
    #expect(drag.draggingPasteboard.writeObjects([writer]))
    let session = PickerReorderSession(board: drag.draggingPasteboard)
    table.dataSource?.outlineView?(table, draggingSession: session, willBeginAt: .zero, forItems: [source])
    let operation = table.dataSource?.outlineView?(table, validateDrop: drag, proposedItem: parent, proposedChildIndex: childIndex)
    #expect(operation?.contains(.move) == true)
    #expect(table.dataSource?.outlineView?(table, acceptDrop: drag, item: parent, childIndex: childIndex) == true)
    for _ in 0..<20 { await Task.yield() }
    #expect(library.matches().map(\.id) == [ids[2], ids[0], ids[1]])
    #expect(tab.pickerSelection == ids[2] && tab.root == nil && tab.store.snapshot == nil)
    #expect(RepositoryLibrary(file: library.file, legacy: []).matches().map(\.id) == [ids[2], ids[0], ids[1]])
    table.dataSource?.outlineView?(table, draggingSession: session, endedAt: .zero, operation: .move)
    if let capture = ProcessInfo.processInfo.environment["GITPICO_PICKER_REORDER_CAPTURE"] {
        window.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(200))
        let view = try #require(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: capture))
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func pickerReorderRejectsChangedFiltersQueriesAndBusyOperations() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-picker-reorder-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: [])
    let a = try library.register(root.appendingPathComponent("Alpha"))
    let b = try library.register(root.appendingPathComponent("Beta"))
    let workspace = RepositoryWorkspace(library: library, draftsFile: root.appendingPathComponent("drafts.json"))
    defer { workspace.shutdown() }
    let tab = workspace.activeTab
    tab.pickerFilter = .all
    let view = RepositoryPickerView(workspace: workspace, tab: tab)
    let action = try #require(view.reorderAction)
    for filter: RepositoryLibraryFilter in [.recent, .favorites, .ungrouped, .group(UUID())] {
        tab.pickerFilter = filter
        #expect(view.reorderAction == nil)
        action(IndexSet(integer: 0), 2)
        #expect(library.matches().map(\.id) == [a, b])
    }
    tab.pickerFilter = .all; tab.pickerQuery = "Alpha"
    action(IndexSet(integer: 0), 2)
    #expect(library.matches().map(\.id) == [a, b])
    tab.pickerQuery = ""; tab.store.isBusy = true
    action(IndexSet(integer: 0), 2)
    #expect(library.matches().map(\.id) == [a, b])
    tab.store.isBusy = false
    action(IndexSet(integer: 0), 2)
    #expect(library.matches().map(\.id) == [b, a])
}
