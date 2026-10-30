import AppKit
import Foundation
import SwiftUI
import Testing
@testable import GitPico

@Test @MainActor func pickerOpenBadgeCountsRepositoryPagesInsteadOfRetainedChooserState() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let workspace = RepositoryWorkspace(library: f.store.library, draftsFile: f.root.appendingPathComponent("picker-open-drafts.json"))
    defer { workspace.shutdown() }
    let root = await f.repository.root
    await workspace.open(root)
    let source = workspace.activeTab
    source.store.commitSubject = "Keep chooser draft"
    #expect(workspace.isRepositoryOpen(at: root.path))
    workspace.showRepositories(from: source.store)
    #expect(source.root == root && source.store.snapshot?.root == root)
    #expect(source.displayedRepositoryPath == nil && !workspace.isRepositoryOpen(at: root.path))
    #expect(source.store.commitSubject == "Keep chooser draft")
    workspace.returnToRepository(from: source.store)
    let chooser = workspace.newTab()
    #expect(chooser.showsRepositoryPicker && workspace.isRepositoryOpen(at: root.path))
    // A different chooser may retain the same path without actually displaying that repository.
    chooser.root = root
    chooser.isChoosingRepository = true
    workspace.showRepositories(from: source.store)
    #expect(!workspace.isRepositoryOpen(at: root.path))
    chooser.isChoosingRepository = false
    #expect(!workspace.isRepositoryOpen(at: root.path), "A root without a matching loaded snapshot is not open.")
    workspace.returnToRepository(from: source.store)
    source.isOpening = true
    #expect(!workspace.isRepositoryOpen(at: root.path))
    source.isOpening = false
    #expect(workspace.isRepositoryOpen(at: root.path))
    source.store.isBusy = true
    #expect(workspace.isRepositoryOpen(at: root.path), "Git activity does not hide an otherwise open repository page.")
    source.store.isBusy = false
    #expect(workspace.close(source.id))
    #expect(!workspace.isRepositoryOpen(at: root.path))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_CAPTURE_PICKER_ROWS"] == "1", "Explicit offscreen picker contrast captures."))
@MainActor func capturePickerRowSelectionContrastWithoutWindows() async throws {
    let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_PICKER_ROWS_OUTPUT"]))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let entry = SavedRepository(id: UUID(), path: "/Users/demo/files/Github/Costaware-iOS copy", name: "Costaware-iOS copy", group: nil, favorite: true, lastOpened: Date())
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.styleMask = [.borderless]; window.contentMinSize = .zero
    window.setFrame(NSRect(x: -10000, y: -10000, width: 760, height: 250), display: false)
    defer { window.contentView = nil; window.close() }
    for dark in [false, true] {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = VStack(spacing: 10) {
            RepositoryPickerRow(entry: entry, isOpen: true, isSelected: false, open: {})
                .padding(.horizontal, 10)
            RepositoryPickerRow(entry: entry, isOpen: true, isSelected: true, open: {})
                .environment(\.controlActiveState, .key).padding(.horizontal, 10)
                .background(Color(nsColor: .selectedContentBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            RepositoryPickerRow(entry: entry, isOpen: true, isSelected: true, open: {})
                .environment(\.controlActiveState, .inactive).padding(.horizontal, 10)
                .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }.padding(16).frame(width: 760, height: 250).background(Color(nsColor: .controlBackgroundColor))
        let host = NSHostingView(rootView: root); window.contentView = host
        try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(dark ? "picker-rows-dark.png" : "picker-rows-light.png"))
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
