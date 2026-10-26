import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

private actor SearchTestReader: ToolbarSearchReading {
    var fileReads = 0
    var blockFiles = false
    var fileWaiting = false
    var fileContinuation: CheckedContinuation<Void, Never>?
    var blockCommit = false
    var commitWaiting = false
    var commitContinuation: CheckedContinuation<Void, Never>?
    func suspendFiles() { blockFiles = true }
    func suspendCommit() { blockCommit = true }
    func releaseFiles() { blockFiles = false; fileContinuation?.resume(); fileContinuation = nil }
    func releaseCommit() { blockCommit = false; commitContinuation?.resume(); commitContinuation = nil }
    func files(in repository: GitRepository, includeIgnored: Bool) async throws -> [WorkingFileEntry] {
        fileReads += 1
        let files = try await repository.workingFiles(includeIgnored: includeIgnored)
        if blockFiles { fileWaiting = true; await withCheckedContinuation { fileContinuation = $0 } }
        return files
    }
    func commit(_ revision: String, in repository: GitRepository) async throws -> Commit {
        let commit = try await repository.commit(at: revision)
        if blockCommit { commitWaiting = true; await withCheckedContinuation { commitContinuation = $0 } }
        return commit
    }
}

@MainActor private func settled(_ session: ToolbarSearchSession) async {
    await session.indexTask?.value
    await session.queryTask?.value
}

@Test @MainActor func unifiedSearchDefaultReturnOnlyFiltersWithoutRunningMatchingCommand() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    try await f.write("a.txt", "edited\n"); try await f.sync()
    let session = ToolbarSearchSession(store: f.store); defer { session.stop() }
    session.beginEditing(); await settled(session)
    session.updateText("discard"); await settled(session)
    #expect(session.results.contains { $0.id == "command:Discard All Local Changes" })
    #expect(session.selection == nil && f.store.search == "discard")
    #expect(session.submit())
    #expect(!session.visible && session.executionTask == nil && f.store.localChangeRequest == nil)
    #expect(try await GitProcess.run(["show", ":a.txt"], at: f.repository.root).text == "original\n")
    #expect(try String(contentsOf: await f.repository.root.appendingPathComponent("a.txt"), encoding: .utf8) == "edited\n")
}

@Test @MainActor func unifiedSearchActionModePreservesFilterAndKeepsDestructiveActionReviewed() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    try await f.write("a.txt", "edited\n"); try await f.sync()
    f.store.search = "a.txt"
    let session = ToolbarSearchSession(store: f.store); defer { session.stop() }
    session.beginActions(); await settled(session)
    session.updateText("> discard"); await settled(session)
    #expect(f.store.search == "a.txt" && session.presentation.contextTitle == nil)
    let discard = try #require(session.results.first { $0.id == "command:Discard All Local Changes" })
    #expect(session.submit(discard))
    #expect(!session.submit(discard))
    await session.executionTask?.value
    guard case .discard(let paths) = f.store.localChangeRequest?.action else { Issue.record("Expected existing discard review"); return }
    #expect(paths == ["a.txt"] && f.store.search == "a.txt")
    #expect(try String(contentsOf: await f.repository.root.appendingPathComponent("a.txt"), encoding: .utf8) == "edited\n")
    f.store.localChangeRequest = nil
    session.beginActions(); session.updateText("> stage"); session.cancel()
    #expect(session.text == "a.txt" && !session.visible && f.store.staged.isEmpty)
    session.beginActions(); await settled(session); session.beginContextSearch()
    #expect(!session.actionsOnly && session.selection == nil && session.text == "a.txt")
}

@Test @MainActor func unifiedSearchContextRowCannotExecutePreviousKeyboardSelection() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let session = ToolbarSearchSession(store: f.store); defer { session.stop() }
    session.beginEditing(); await settled(session)
    session.move(-1); #expect(session.selection == nil)
    session.move(1); #expect(session.selection != nil)
    session.move(-1); #expect(session.selection == nil)
    session.move(1); session.filterCurrentView()
    #expect(session.selection == nil && session.executionTask == nil && !session.visible)
    session.updateText("branch"); await settled(session)
    session.move(1); #expect(session.selection != nil)
    session.updateText("no match exists")
    #expect(session.results.isEmpty && session.selection == nil)
    #expect(session.submit() && session.executionTask == nil)
}

@Test @MainActor func unifiedSearchCachesFileIndexAndOpensCleanFileThroughExistingRoute() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let reader = SearchTestReader(), session = ToolbarSearchSession(store: f.store, reader: reader)
    defer { session.stop() }
    session.beginEditing(); await settled(session)
    session.endEditing(); session.beginEditing(); await settled(session)
    #expect(await reader.fileReads == 1)
    session.updateText("b.txt"); await settled(session)
    let file = try #require(session.results.first { $0.id == "file:b.txt" })
    #expect(session.submit(file)); await session.executionTask?.value
    let deadline = Date().addingTimeInterval(5)
    while f.store.selectedChange != "b.txt", Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(f.store.selectedChange == "b.txt" && f.store.showAllFiles && f.store.currentChange == nil)
    #expect(f.store.search.isEmpty)
    session.endEditing(); f.store.lastUpdated = Date(); session.invalidate(); session.beginEditing(); await settled(session)
    #expect(await reader.fileReads == 2)
}

@Test @MainActor func unifiedSearchRejectsLateIndexFromReplacedRepositoryAndQueuedActionWhenBusy() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let reader = SearchTestReader(); await reader.suspendFiles()
    let session = ToolbarSearchSession(store: f.store, reader: reader); defer { session.stop() }
    session.beginEditing()
    let deadline = Date().addingTimeInterval(5)
    while !(await reader.fileWaiting), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await reader.fileWaiting)
    f.store.repositoryToken = UUID(); session.invalidate(); await reader.releaseFiles(); await settled(session)
    #expect(session.results.isEmpty && !session.visible)
    session.beginActions(); await settled(session); session.updateText("> Create Branch"); await settled(session)
    let branch = try #require(session.results.first { $0.id == "command:Create Branch" })
    #expect(session.submit(branch)); f.store.isBusy = true; await session.executionTask?.value
    #expect(f.store.managementRequest == nil)
    f.store.isBusy = false
    session.beginActions(); await settled(session); session.updateText("> Create Branch"); await settled(session)
    #expect(session.submit(branch)); f.store.repositoryToken = UUID(); await session.executionTask?.value
    #expect(f.store.managementRequest == nil)
    #expect(!session.submit(branch))
}

@Test @MainActor func unifiedSearchRejectsLateHashLookupAfterNewQuery() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let reader = SearchTestReader(); await reader.suspendCommit()
    let session = ToolbarSearchSession(store: f.store, reader: reader); defer { session.stop() }
    session.beginEditing(); await settled(session)
    let commit = try await f.repository.commit(at: "HEAD")
    session.updateText(commit.hash)
    let deadline = Date().addingTimeInterval(5)
    while !(await reader.commitWaiting), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await reader.commitWaiting)
    let obsolete = session.queryTask
    session.updateText("b.txt"); await session.queryTask?.value
    await reader.releaseCommit(); await obsolete?.value
    #expect(!session.results.contains { $0.id == "commit:" + commit.hash })
    #expect(session.results.contains { $0.id == "file:b.txt" })
}

@MainActor private final class ComposingSearchEditor: NSTextView {
    override func hasMarkedText() -> Bool { true }
}

@Test @MainActor func unifiedSearchKeyboardBridgeDefersIMEAndNeverPresentsBackgroundPanel() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let session = ToolbarSearchSession(store: f.store); defer { session.stop() }
    session.beginEditing(); await settled(session)
    let coordinator = ToolbarSearchField.Coordinator(text: Binding(get: { session.text }, set: { session.updateText($0) }))
    let field = NSSearchField(), editor = NSTextView()
    coordinator.update(field, session: session, presentation: session.presentation)
    #expect(coordinator.panel == nil)
    let composing = ComposingSearchEditor()
    #expect(!coordinator.control(field, textView: composing, doCommandBy: #selector(NSResponder.moveDown(_:))))
    #expect(session.selection == nil)
    #expect(!coordinator.control(field, textView: composing, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    #expect(session.selection != nil)
    #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(!session.visible && session.executionTask == nil)
    coordinator.stop()
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RENDER_COMPONENTS"] == "1", "Explicit offscreen component capture only."))
@MainActor func renderUnifiedSearchSuggestionsWithoutWindows() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let session = ToolbarSearchSession(store: f.store); defer { session.stop() }
    session.beginEditing(); await settled(session)
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_COMPONENT_OUTPUT"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for actions in [false, true] {
        if actions { session.beginActions(); session.updateText("> branch") } else { session.updateText("b.txt") }
        await settled(session)
        for scheme in [ColorScheme.light, .dark] {
            let content = ToolbarSearchSuggestions(session: session).frame(width: 560, height: session.presentation.height).environment(\.colorScheme, scheme).environment(\.controlActiveState, .key)
            #expect(!session.results.isEmpty)
            let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
            window.tabbingMode = .disallowed; window.styleMask = [.borderless]; window.contentMinSize = .zero
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: content)
            window.contentView = host
            window.setFrame(NSRect(x: -10000, y: -10000, width: 560, height: session.presentation.height), display: false)
            for _ in 0..<10 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(120))
            host.layoutSubtreeIfNeeded()
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let data = try #require(image.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("unified-search-\(actions ? "actions" : "files")-\(scheme == .dark ? "dark" : "light").png"))
            window.close()
        }
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
