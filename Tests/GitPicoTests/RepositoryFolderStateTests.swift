import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@MainActor private struct FolderStateFixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GitPico-folder-state-\(UUID())")
    let library: RepositoryLibrary

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: [])
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test @MainActor func savedFolderDeletionRestorationAndRelocationRefreshWithoutChangingMetadata() async throws {
    let f = try FolderStateFixture(); defer { f.clean() }
    let path = f.root.appendingPathComponent("Repo")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    let id = try f.library.recordOpened(path)
    try f.library.setFavorite([id], true)
    try f.library.rename([id], to: "Custom Name")
    let entry = try #require(f.library.document.repositories.first)
    let originalDocument = f.library.document, originalData = try Data(contentsOf: f.library.file)
    #expect(f.library.folderState(for: entry) == .checking)
    await f.library.refreshFolderStates()
    #expect(f.library.folderState(for: entry) == .available)
    try FileManager.default.removeItem(at: path)
    await f.library.refreshFolderStates()
    #expect(f.library.folderState(for: entry) == .missing)
    #expect(!f.library.folderState(for: entry).canOpen)
    #expect(f.library.folderState(for: entry).warning == "Folder Missing")
    #expect(f.library.document == originalDocument && f.library.error == nil)
    #expect(try Data(contentsOf: f.library.file) == originalData)
    let reopened = RepositoryLibrary(file: f.library.file, legacy: [])
    await reopened.refreshFolderStates()
    #expect(reopened.folderState(for: entry) == .missing)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    await f.library.refreshFolderStates()
    #expect(f.library.folderState(for: entry).canOpen)
    let moved = f.root.appendingPathComponent("Moved")
    try FileManager.default.moveItem(at: path, to: moved)
    await f.library.refreshFolderStates()
    #expect(f.library.folderState(for: entry) == .missing)
    try f.library.relocate(id, to: moved)
    await f.library.refreshFolderStates()
    let updated = try #require(f.library.document.repositories.first)
    #expect(updated.id == entry.id && updated.name == entry.name && updated.favorite == entry.favorite && updated.lastOpened == entry.lastOpened)
    #expect(f.library.folderState(for: updated).canOpen)
    #expect(f.library.folderStates[entry.path] == nil)
}

@Test @MainActor func savedFolderFileReplacementAndSymlinksAreClassifiedCorrectly() async throws {
    let f = try FolderStateFixture(); defer { f.clean() }
    let target = f.root.appendingPathComponent("Target"), alias = f.root.appendingPathComponent("Alias")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    #expect(RepositoryFolderState.read(path: alias.path) == .available)
    _ = try f.library.register(target)
    let entry = try #require(f.library.document.repositories.first)
    try FileManager.default.removeItem(at: target)
    #expect(RepositoryFolderState.read(path: alias.path) == .missing)
    try Data("not a folder".utf8).write(to: target)
    await f.library.refreshFolderStates()
    #expect(f.library.folderState(for: entry) == .unavailable)
    #expect(f.library.folderState(for: entry).warning == "Folder Unavailable")
    #expect(!f.library.folderState(for: entry).canOpen)
    let locked = f.root.appendingPathComponent("Locked"), child = locked.appendingPathComponent("Repo")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
    #expect(RepositoryFolderState.read(path: child.path) == .unavailable, "A permission error must not claim that the folder was deleted.")
}

@Test @MainActor func savedMissingFolderCannotOpenEvenWhenTheCachedStateWasAvailable() async throws {
    let f = try FolderStateFixture(); defer { f.clean() }
    let active = f.root.appendingPathComponent("Active"), missing = f.root.appendingPathComponent("Missing")
    for url in [active, missing] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await GitProcess.run(["init", "-q", "-b", "main"], at: url)
    }
    _ = try f.library.register(missing)
    let entry = try #require(f.library.document.repositories.first)
    let store = RepositoryStore(library: f.library)
    await store.open(active)
    await f.library.refreshFolderStates()
    #expect(f.library.folderState(for: entry).canOpen)
    let document = f.library.document, data = try Data(contentsOf: f.library.file)
    try FileManager.default.removeItem(at: missing)
    await store.openSavedRepository(entry)
    #expect(store.error?.contains("Folder Missing") == true)
    #expect(f.library.folderState(for: entry) == .missing)
    #expect(store.snapshot?.root.path == active.path && !store.isBusy)
    #expect(f.library.document == document)
    #expect(try Data(contentsOf: f.library.file) == data)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_CAPTURE_MISSING_FOLDERS"] == "1", "Explicit offscreen folder state captures."))
@MainActor func captureMissingFolderRowsWithoutPresentingWindows() async throws {
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_MISSING_FOLDERS_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let entry = SavedRepository(id: UUID(), path: "/Users/demo/files/Github/FlightWallpaper", name: "FlightWallpaper", favorite: true, lastOpened: Date())
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.styleMask = [.borderless]; window.contentMinSize = .zero
    window.setFrame(NSRect(x: -10000, y: -10000, width: 800, height: 340), display: false)
    defer { window.contentView = nil; window.close() }
    for dark in [false, true] {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = VStack(spacing: 10) {
            RepositoryPickerRow(entry: entry, isOpen: false, isSelected: false, folderState: .available, open: {})
            RepositoryPickerRow(entry: entry, isOpen: true, isSelected: false, folderState: .missing, open: {})
            RepositoryPickerRow(entry: entry, isOpen: true, isSelected: true, folderState: .missing, open: {})
                .environment(\.controlActiveState, .key)
                .background(Color(nsColor: .selectedContentBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            RepositoryPickerRow(entry: entry, isOpen: true, isSelected: true, folderState: .missing, open: {})
                .environment(\.controlActiveState, .inactive)
                .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }.padding(16).frame(width: 800, height: 340).background(Color(nsColor: .controlBackgroundColor))
        let host = NSHostingView(rootView: root); window.contentView = host
        try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(dark ? "missing-folder-dark.png" : "missing-folder-light.png"))
    }
    let f = try FolderStateFixture(); defer { f.clean() }
    let id = try f.library.register(f.root.appendingPathComponent("FlightWallpaper"))
    let workspace = RepositoryWorkspace(library: f.library, draftsFile: f.root.appendingPathComponent("drafts.json"))
    defer { workspace.shutdown() }
    let tab = workspace.activeTab
    tab.pickerFilter = .all; tab.pickerSelection = id
    window.setFrame(NSRect(x: -10000, y: -10000, width: 1050, height: 700), display: false)
    for dark in [false, true] {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: RepositoryPickerView(workspace: workspace, tab: tab, showsSidebar: false)
            .frame(width: 1050, height: 700).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
        let saved = try #require(f.library.document.repositories.first)
        #expect(f.library.folderState(for: saved) == .missing, "The picker starts filesystem checks when shown.")
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(dark ? "missing-folder-picker-dark.png" : "missing-folder-picker-light.png"))
    }
    let saved = try #require(f.library.document.repositories.first)
    try FileManager.default.createDirectory(atPath: saved.path, withIntermediateDirectories: true)
    let deadline = ContinuousClock.now + .seconds(5)
    while f.library.folderState(for: saved) != .available && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(f.library.folderState(for: saved) == .available, "The visible picker automatically notices a restored folder.")
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
