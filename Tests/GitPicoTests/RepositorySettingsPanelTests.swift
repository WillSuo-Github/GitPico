import AppKit
import SwiftUI
import Testing
@testable import GitPico
import GitCore

@Test @MainActor func repositorySettingsKeepsHistoryAndReturnsWithoutRepositoryNavigation() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let workspace = RepositoryWorkspace(library: f.store.library, draftsFile: f.root.appendingPathComponent("settings-drafts.json"))
    defer { workspace.shutdown() }
    await workspace.open(f.repository.root)
    let store = workspace.activeStore, visits = workspace.repositoryVisits
    store.navigate(.history); await store.historyTask?.value; await store.detailTask?.value
    let commit = try #require(store.selectedCommit)
    store.search = "Files"; store.commitSubject = "Keep draft"
    let bookmarks = store.navigationBookmarks
    store.navigate(.repositorySettings)
    #expect(store.showingRepositorySettings && store.destination == .history)
    #expect(store.selectedCommit?.hash == commit.hash && store.search == "Files")
    #expect(store.navigationBookmarks == bookmarks && store.canGoBack && !store.canGoForward)
    store.goBack()
    #expect(store.settingsNavigationRequest == .history && store.showingRepositorySettings)
    store.finishRepositorySettings()
    #expect(!store.showingRepositorySettings && store.settingsNavigationRequest == nil)
    #expect(store.destination == .history && store.selectedCommit?.hash == commit.hash)
    #expect(store.search == "Files" && store.commitSubject == "Keep draft")
    #expect(workspace.repositoryVisits == visits && !store.isChoosingRepository)
    store.navigate(.repositorySettings); store.navigate(.workingCopy)
    #expect(store.destination == .history && store.settingsNavigationRequest == .workingCopy)
    store.finishRepositorySettings()
    #expect(store.destination == .workingCopy)
}

@Test @MainActor func repositorySettingsSavesDraftsAcrossCategoriesWithoutStaging() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let draft = RepositorySettingsDraft()
    draft.load(try await f.repository.configuration())
    #expect(!draft.hasChanges && !draft.canSave)
    await draft.ignores.load(from: f.repository); await draft.excludes.load(from: f.repository)
    draft.general?.name = "Settings Author"
    draft.ignores.text = "build/\n"; draft.excludes.text = "private/\n"
    f.store.settingsTab = "Ignores"; f.store.settingsTab = "General"; f.store.settingsTab = "Excludes"
    #expect(draft.hasChanges && draft.ignores.text == "build/\n" && draft.canSave)
    #expect(await draft.save(in: f.store))
    #expect(!draft.hasChanges && !draft.saving && f.store.error == nil)
    #expect(try await f.repository.readIdentity().name == "Settings Author")
    #expect(try await f.repository.readIgnoreFile(.ignores) == "build/\n")
    #expect(try await f.repository.readIgnoreFile(.excludes) == "private/\n")
    #expect(try await GitProcess.run(["diff", "--cached", "--name-only"], at: f.repository.root).data.isEmpty)
}

@Test @MainActor func repositorySettingsKeepsUnsavedDraftAfterConflictAndPartialSave() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let draft = RepositorySettingsDraft(); draft.load(try await f.repository.configuration())
    await draft.ignores.load(from: f.repository)
    draft.general?.name = "Saved before conflict"; draft.ignores.text = "my-rule/\n"
    try await f.write(".gitignore", "external-rule/\n")
    #expect(await draft.save(in: f.store) == false)
    #expect(draft.hasChanges && !draft.generalIsDirty && draft.ignores.isDirty && draft.failure != nil)
    #expect(draft.ignores.text == "my-rule/\n" && !draft.saving && !f.store.isBusy)
    #expect(try await f.repository.readIgnoreFile(.ignores) == "external-rule/\n")
    draft.general?.name = ""
    #expect(!draft.canSave)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_CAPTURE_SETTINGS_PANEL"] == "1", "Explicit offscreen settings captures."))
@MainActor func captureRepositorySettingsPanelWithoutWindows() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_SETTINGS_PANEL_OUTPUT"]))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let draft = RepositorySettingsDraft(); draft.load(try await f.repository.configuration())
    await draft.ignores.load(from: f.repository); draft.ignores.text = "build/\nDerivedData/\n"
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.styleMask = [.borderless]; window.contentMinSize = .zero
    window.setFrame(NSRect(x: -10000, y: -10000, width: 850, height: 660), display: false)
    defer { window.contentView = nil; window.close() }
    for (tab, dark) in [("General", false), ("General", true), ("Ignores", false)] {
        f.store.settingsTab = tab
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let content = RepositorySettingsView(store: f.store, draft: draft).environment(\.controlActiveState, .key)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: content); window.contentView = host
        try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(tab + (dark ? "-dark" : "") + ".png"))
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
