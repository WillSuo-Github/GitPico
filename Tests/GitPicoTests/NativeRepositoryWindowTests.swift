import AppKit
import Foundation
import GitCore
import Testing
@testable import GitPico

@Test @MainActor func nativeSessionRestoresDetachedGroupsAndVisualTabOrderWithoutWindows() async throws {
    let f = try await NativeTabFixture.make(); defer { f.clean() }
    let first = f.workspace.activeTab.id
    let second = f.workspace.newTab().id
    let third = f.workspace.newTab().id
    let groups = [WorkspaceWindowGroup(tabs: [second, first], selected: first, x: 100, y: 100, width: 1420, height: 900),
                  WorkspaceWindowGroup(tabs: [third], selected: third, x: 200, y: 200, width: 1420, height: 900)]
    f.windows.restoreWindows(groups)
    let restored = f.windows.sessionWindows()
    #expect(restored.contains { $0.tabs == [second, first] && $0.selected == first })
    #expect(restored.contains { $0.tabs == [third] })
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func heldLaunchDefersNativeTabSelectionUntilPresentation() async throws {
    let f = try await NativeTabFixture.make(); defer { f.clean() }
    let first = f.workspace.activeTab.id
    let second = f.workspace.newTab().id
    let firstWindow = try #require(f.windows.window(for: first)), secondWindow = try #require(f.windows.window(for: second))
    #expect(firstWindow.tabGroup?.selectedWindow === secondWindow)
    f.windows.holdPresentation()
    // Selecting a tab in a hidden native group would order it on screen, so the choice waits for release.
    f.workspace.select(first)
    #expect(f.windows.presentationHeld && f.workspace.selectedID == first)
    #expect(firstWindow.tabGroup?.selectedWindow === secondWindow)
    f.windows.releasePresentation()
    #expect(!f.windows.presentationHeld)
    #expect(firstWindow.tabGroup?.selectedWindow === firstWindow && f.workspace.selectedID == first)
    f.windows.holdPresentation()
    f.windows.reopen()
    #expect(!f.windows.presentationHeld)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@MainActor private struct NativeTabFixture {
    let base: WorkingAppFixture
    let workspace: RepositoryWorkspace
    let windows: NativeRepositoryWindows
    static func make(corruptDrafts: Bool = false) async throws -> Self {
        let base = try await WorkingAppFixture.make()
        let file = base.root.appendingPathComponent("native-drafts.json")
        if corruptDrafts { try Data("broken".utf8).write(to: file) }
        let workspace = RepositoryWorkspace(library: base.store.library, draftsFile: file)
        await workspace.open(await base.repository.root)
        let windows = NativeRepositoryWindows(workspace: workspace, permitsPresentation: false)
        windows.start()
        return Self(base: base, workspace: workspace, windows: windows)
    }
    func clean() {
        windows.stop(); workspace.shutdown()
        for tab in workspace.tabs { tab.store.cancelPreviewWork(); tab.store.metadataTask?.cancel() }
        base.clean()
    }
}

@Test @MainActor func nativeWindowTabsSynchronizeSelectionCreationAndBusyClose() async throws {
    let f = try await NativeTabFixture.make(); defer { f.clean() }
    let w = f.workspace, first = w.activeTab
    let firstWindow = try #require(f.windows.window(for: first.id))
    #expect(firstWindow.tabGroup?.isTabBarVisible == false)
    first.store.commitSubject = "Keep native tab draft"
    first.store.showRepositories()
    #expect(w.tabs.count == 1 && first.showsRepositoryPicker && f.windows.window(for: first.id) === firstWindow)
    #expect(firstWindow.tabGroup?.isTabBarVisible == false)
    // Only the picker lets its gradient run under the toolbar; repository pages keep the titlebar scroll-edge effect.
    try await Task.sleep(for: .milliseconds(300))
    #expect(firstWindow.titlebarAppearsTransparent)
    w.returnToRepository(from: first.store)
    #expect(!first.showsRepositoryPicker && first.store.commitSubject == "Keep native tab draft")
    try await Task.sleep(for: .milliseconds(300))
    #expect(!firstWindow.titlebarAppearsTransparent)
    let second = w.newTab()
    let secondWindow = try #require(f.windows.window(for: second.id))
    #expect(firstWindow.tabGroup === secondWindow.tabGroup)
    #expect(firstWindow.tabGroup?.windows.count == 2 && firstWindow.tabGroup?.isTabBarVisible == true)
    #expect(firstWindow.tabGroup?.selectedWindow === secondWindow)
    firstWindow.tabGroup?.selectedWindow = firstWindow
    #expect(w.selectedID == first.id && w.activeStore.commitSubject == "Keep native tab draft")
    secondWindow.newWindowForTab(nil)
    #expect(w.tabs.count == 3 && f.windows.controllers.count == 3 && w.activeTab.root == nil)
    let third = w.activeTab
    #expect(w.close(third.id) && f.windows.controllers.count == 2)
    w.select(first.id)
    first.store.isBusy = true
    f.windows.updateDescriptor(first.id)
    #expect(firstWindow.tab.accessoryView is NSProgressIndicator)
    firstWindow.performClose(nil)
    #expect(w.tabs.contains(where: { $0.id == first.id }) && w.error != nil)
    w.select(second.id)
    #expect(firstWindow.tabGroup?.selectedWindow === secondWindow && first.store.isBusy)
    first.store.isBusy = false; w.error = nil
    #expect(w.close(first.id))
    #expect(f.windows.window(for: first.id) == nil && w.activeTab.id == second.id)
    #expect(secondWindow.tabGroup?.isTabBarVisible == false)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func nativeWindowHistoryNavigatesThroughLibraryWithoutCreatingOrShowingWindows() async throws {
    let f = try await NativeTabFixture.make(); defer { f.clean() }
    let w = f.workspace, tab = w.activeTab
    let window = try #require(f.windows.window(for: tab.id))
    tab.store.commitSubject = "Keep native navigation draft"
    await w.navigateRepositories(.back, from: tab.store)
    f.windows.updateDescriptor(tab.id)
    #expect(tab.showsRepositoryPicker && window.title == String(localized: "Repositories"))
    #expect(window.titlebarAppearsTransparent && !tab.store.canGoBack && tab.store.canGoForward)
    await w.navigateRepositories(.forward, from: tab.store)
    f.windows.updateDescriptor(tab.id)
    #expect(!tab.showsRepositoryPicker && window.title == tab.title && !window.titlebarAppearsTransparent)
    #expect(tab.store.commitSubject == "Keep native navigation draft")
    #expect(w.tabs.count == 1 && f.windows.window(for: tab.id) === window)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func nativeWindowCloseProtectsDraftAndReopensLastChooser() async throws {
    let f = try await NativeTabFixture.make(corruptDrafts: true); defer { f.clean() }
    let w = f.workspace, original = w.activeTab
    original.store.commitSubject = "Protect draft from native close"
    let originalWindow = try #require(f.windows.window(for: original.id))
    originalWindow.performClose(nil)
    #expect(w.tabs.count == 1 && w.activeTab === original && w.error != nil)
    #expect(f.windows.window(for: original.id) === originalWindow)
    try Data("{}".utf8).write(to: w.drafts.file)
    w.flushDrafts(); w.error = nil
    originalWindow.performClose(nil)
    #expect(w.tabs.count == 1 && w.activeTab.root == nil && w.activeTab.id != original.id)
    let picker = w.activeTab
    let pickerWindow = try #require(f.windows.window(for: picker.id))
    pickerWindow.performClose(nil)
    #expect(f.windows.controllers.isEmpty && w.tabs.count == 1)
    f.windows.reopen()
    #expect(f.windows.controllers.count == 1 && w.selectedID == picker.id)
    f.windows.window(for: picker.id)?.performClose(nil)
    w.newTab()
    #expect(f.windows.controllers.count == 1 && w.tabs.count == 1 && w.selectedID != picker.id)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func nativeWindowTabCyclingFollowsVisualOrderAndDetachedGroups() async throws {
    let f = try await NativeTabFixture.make(); defer { f.clean() }
    let w = f.workspace, firstID = w.selectedID
    let second = w.newTab(), third = w.newTab()
    let first = try #require(f.windows.window(for: firstID))
    let group = try #require(first.tabGroup)
    group.insertWindow(first, at: 2)
    w.select(firstID)
    let order = group.windows.compactMap { ($0 as? RepositoryNativeWindow)?.tabID }
    w.cycle(1)
    #expect(w.selectedID == order[0])
    let detached = try #require(f.windows.window(for: third.id))
    group.removeWindow(detached)
    #expect(detached.tabGroup?.isTabBarVisible == false)
    #expect(group.isTabBarVisible)
    w.select(third.id)
    w.cycle(1)
    #expect(w.selectedID == third.id)
    let added = w.newTab()
    #expect(f.windows.window(for: added.id)?.tabGroup === detached.tabGroup)
    #expect(detached.tabGroup?.isTabBarVisible == true)
    #expect(f.windows.window(for: second.id)?.tabGroup !== detached.tabGroup)
    let another = f.base.root.appendingPathComponent("Opened from another group")
    _ = try await GitRepository.create(at: another)
    let count = w.tabs.count
    await w.open(another, from: w.tabs.first { $0.id == firstID }?.store)
    #expect(w.tabs.count == count && w.selectedID == firstID && f.windows.window(for: firstID) === first)
    #expect(f.windows.window(for: w.selectedID)?.tabGroup === first.tabGroup)
    #expect(f.windows.window(for: w.selectedID)?.tabGroup !== detached.tabGroup)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RENDER_NATIVE_TABS"] == "1", "Explicit suppressed native tab rendering only."))
@MainActor func renderNativeWindowTabsWithoutActivation() async throws {
    let f = try await NativeTabFixture.make(); defer { f.clean() }
    let w = f.workspace, first = w.activeTab, root = await f.base.repository.root
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_NATIVE_TABS_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let id = try w.library.register(root)
    try w.library.rename([id], to: "GitPico")
    let before = """
    import SwiftUI

    struct RepositoryWorkspaceView: View {
        var body: some View {
            VStack(spacing: 0) {
                SidebarView()
                ContentView()
            }
        }
    }

    """
    try await f.base.write("RepositoryWorkspaceView.swift", before)
    try await f.base.write("README.md", "# GitPico\n\nA native Git client.\n")
    _ = try await GitProcess.run(["add", "."], at: root)
    _ = try await GitProcess.run(["commit", "-m", "Native window tab capture baseline"], at: root)
    try await f.base.write("RepositoryWorkspaceView.swift", before.replacingOccurrences(of: "VStack(spacing: 0)", with: "NavigationSplitView"))
    try await f.base.write("README.md", "# GitPico\n\nA native Git client with window tabs.\n")
    try await f.base.write("WorkspaceTests.swift", "import Testing\n\n@Test func nativeTabsKeepRepositoryState() {}\n")
    _ = try await GitProcess.run(["add", "README.md"], at: root)
    first.store.snapshot = try await f.base.repository.snapshot()
    await first.store.rebuildWorkingList()
    first.store.commitSubject = "Improve repository navigation"
    first.store.setWorkingSelection(["RepositoryWorkspaceView.swift"])
    await first.store.detailTask?.value
    for name in ["Costaware-iOS", "Website"] {
        let url = f.base.root.appendingPathComponent(name)
        _ = try await GitRepository.create(at: url)
        w.newTab(); await w.open(url)
    }
    w.select(first.id)
    let window = try #require(f.windows.window(for: first.id))
    let content = try #require(window.contentViewController?.view)
    content.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    first.store.setWorkingSelection(["RepositoryWorkspaceView.swift"])
    await first.store.detailTask?.value
    for dark in [false, true] {
        for width: CGFloat in [1080, 1440] {
            for controller in f.windows.controllers.values { controller.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: width, height: 900)), display: false)
            f.windows.updateDescriptor(first.id)
            for _ in 0..<20 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(300))
            let view = try #require(window.contentView?.superview)
            view.layoutSubtreeIfNeeded()
            #expect(first.store.selectedChange == "RepositoryWorkspaceView.swift")
            #expect(window.tabGroup?.isTabBarVisible == true && window.tabGroup?.windows.count == 3)
            #expect(window.tabGroup?.selectedWindow === window)
            let toolbar = try #require(window.toolbar)
            #expect(toolbar.displayMode == .iconOnly)
            let controls = toolbar.items.filter { $0.view != nil }
            if width == 1440 { #expect(controls.allSatisfy { item in toolbar.visibleItems?.contains(where: { $0 === item }) == true }) }
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("native-tabs-\(Int(width))-\(dark ? "dark" : "light").png"))
            let geometry: [String: Any] = ["window": NSStringFromRect(window.frame), "content": NSStringFromRect(window.contentLayoutRect), "toolbarLabels": controls.map(\.label), "visibleControlCount": toolbar.visibleItems?.filter { $0.view != nil }.count ?? 0, "controlCount": controls.count, "tabTitles": window.tabGroup?.windows.map { $0.tab.title } ?? []]
            try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-tabs-\(Int(width))-\(dark ? "dark" : "light").json"))
        }
    }
    w.cycle(1); w.cycle(-1)
    #expect(w.selectedID == first.id && f.windows.window(for: first.id)?.contentViewController?.view === content)
    #expect(first.store.commitSubject == "Improve repository navigation" && first.store.selectedChange == "RepositoryWorkspaceView.swift")
    first.store.showRepositories()
    let picker = first
    for tab in w.tabs where tab.id != picker.id { _ = w.close(tab.id) }
    let pickerWindow = try #require(f.windows.window(for: picker.id))
    pickerWindow.appearance = NSAppearance(named: .darkAqua)
    pickerWindow.setFrame(NSRect(origin: pickerWindow.frame.origin, size: NSSize(width: 1440, height: 980)), display: false)
    try await Task.sleep(for: .milliseconds(500))
    let pickerFrame = try #require(pickerWindow.contentView?.superview)
    pickerFrame.layoutSubtreeIfNeeded()
    let pickerBitmap = try #require(pickerFrame.bitmapImageRepForCachingDisplay(in: pickerFrame.bounds))
    pickerFrame.cacheDisplay(in: pickerFrame.bounds, to: pickerBitmap)
    try #require(pickerBitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("repository-picker-dark.png"))
    func hierarchy(_ view: NSView, depth: Int = 0) -> String {
        let row = String(repeating: "  ", count: depth) + String(describing: type(of: view)) + " " + NSStringFromRect(view.frame) + " safe=" + String(describing: view.safeAreaInsets) + " hidden=" + String(view.isHidden) + " next=" + String(describing: view.nextResponder.map { type(of: $0) }) + "\n"
        return row + view.subviews.map { hierarchy($0, depth: depth + 1) }.joined()
    }
    try hierarchy(pickerFrame).write(to: output.appendingPathComponent("repository-picker-views.txt"), atomically: true, encoding: .utf8)
    w.returnToRepository(from: first.store)
    #expect(w.tabs.count == 1 && !first.showsRepositoryPicker && first.store.commitSubject == "Improve repository navigation")
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
