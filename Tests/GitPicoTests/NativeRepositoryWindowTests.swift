import AppKit
import Foundation
import GitCore
import Sparkle
import Testing
@testable import GitPico

@Test @MainActor func nativeSessionRestoresThreeAndFourTabsInSavedVisualOrder() async throws {
    for held in [false, true] {
        let f = try await NativeTabFixture.make(); defer { f.clean() }
        let ids = [f.workspace.activeTab.id, f.workspace.newTab().id, f.workspace.newTab().id, f.workspace.newTab().id]
        for order in [[ids[0], ids[1], ids[2]], [ids[2], ids[0], ids[3], ids[1]]] {
            let selected = order[1]
            var groups = [WorkspaceWindowGroup(tabs: order, selected: selected, x: 100, y: 100, width: 1420, height: 900)]
            if let detached = ids.first(where: { !order.contains($0) }) {
                groups.append(WorkspaceWindowGroup(tabs: [detached], selected: detached, x: 200, y: 200, width: 1420, height: 900))
            }
            // Repeated restore must be stable, both during held launch and on a live group.
            for _ in 0..<2 {
                if held { f.windows.holdPresentation() }
                f.workspace.select(selected)
                f.windows.restoreWindows(groups)
                if held { f.windows.releasePresentation() }
                let group = try #require(f.windows.window(for: selected)?.tabGroup)
                #expect(group.windows.compactMap { ($0 as? RepositoryNativeWindow)?.tabID } == order)
                #expect((group.selectedWindow as? RepositoryNativeWindow)?.tabID == selected)
                #expect(f.windows.sessionWindows().contains { $0.tabs == order && $0.selected == selected })
                f.workspace.cycle(1)
                #expect(f.workspace.selectedID == order[2])
            }
        }
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func terminationWindowTeardownKeepsSavedTabsAndNavigation() async throws {
    let f = try await NativeTabFixture.make(); defer { f.clean() }
    let workspace = f.workspace
    let first = workspace.activeTab
    first.store.navigate(.history)
    await first.store.historyTask?.value; await first.store.detailTask?.value
    let selectedCommit = first.store.selectedCommit?.hash
    first.store.commitSubject = "Keep across update restart"
    let secondRoot = f.base.root.appendingPathComponent("Second")
    _ = try await GitRepository.create(at: secondRoot)
    let second = workspace.newTab()
    await workspace.open(secondRoot)
    let chooser = workspace.newTab()
    workspace.select(first.id)
    f.windows.restoreWindows([
        WorkspaceWindowGroup(tabs: [second.id, first.id], selected: first.id, x: 100, y: 100, width: 1420, height: 900),
        WorkspaceWindowGroup(tabs: [chooser.id], selected: chooser.id, x: 200, y: 200, width: 1420, height: 900)
    ])
    let update = UpdateController(workspace: workspace)
    let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: update, userDriverDelegate: nil).updater
    #expect(update.updaterShouldRelaunchApplication(updater))
    #expect(!workspace.isShuttingDown)
    first.store.commitBody = "Edited after the restart checkpoint"
    update.updaterWillRelaunchApplication(updater)
    #expect(workspace.shutdown())
    let saved = try Data(contentsOf: workspace.session.file)
    let closingWindows = workspace.tabs.compactMap { f.windows.window(for: $0.id) }
    // AppKit can send close notifications after accepting the application's Quit event.
    for window in closingWindows { window.close() }
    workspace.saveSession()
    #expect(try Data(contentsOf: workspace.session.file) == saved)

    f.windows.stop()
    let reopened = RepositoryWorkspace(library: workspace.library, draftsFile: workspace.drafts.file)
    let windows = NativeRepositoryWindows(workspace: reopened, permitsPresentation: false)
    windows.holdPresentation(); windows.start()
    defer { windows.stop(); reopened.shutdown() }
    await reopened.restoreSavedSession()
    windows.releasePresentation()
    #expect(reopened.tabs.map(\.id) == [first.id, second.id, chooser.id])
    #expect(reopened.selectedID == first.id && reopened.activeStore.destination == .history)
    #expect(reopened.activeStore.selectedCommit?.hash == selectedCommit)
    #expect(reopened.activeStore.commitSubject == "Keep across update restart")
    #expect(reopened.activeStore.commitBody == "Edited after the restart checkpoint")
    #expect(windows.sessionWindows().contains { $0.tabs == [second.id, first.id] && $0.selected == first.id })
    #expect(windows.sessionWindows().contains { $0.tabs == [chooser.id] })
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func sparkleRestartRefusesBusyOrUnsavedWorkspaceAndAllowsRetry() async throws {
    let f = try await NativeTabFixture.make(); defer { f.clean() }
    let workspace = f.workspace
    let update = UpdateController(workspace: workspace)
    let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: update, userDriverDelegate: nil).updater
    workspace.activeStore.isBusy = true
    #expect(!update.updaterShouldRelaunchApplication(updater))
    #expect(!workspace.isShuttingDown)
    workspace.activeStore.isBusy = false

    let external = Data("externally changed workspace".utf8)
    try external.write(to: workspace.session.file)
    #expect(!update.updaterShouldRelaunchApplication(updater))
    #expect(!workspace.shutdown())
    #expect(workspace.sessionSaveWarning != nil && !workspace.isShuttingDown)
    #expect(try Data(contentsOf: workspace.session.file) == external)
    workspace.activeStore.commitSubject = "The cancelled restart is still editable"
    try FileManager.default.removeItem(at: workspace.session.file)
    workspace.retrySessionSave()
    #expect(update.updaterShouldRelaunchApplication(updater))
    #expect(!workspace.isShuttingDown && workspace.sessionSaveWarning == nil)
    #expect(RepositoryDraftStore(file: workspace.drafts.file).values[workspace.activeTab.root!.path]?.subject == "The cancelled restart is still editable")
    #expect(workspace.shutdown())
}

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
    #expect(f.windows.presentationHeld)
    f.windows.releasePresentation()
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
    // Both destinations draw their background through the native toolbar.
    try await Task.sleep(for: .milliseconds(300))
    #expect(firstWindow.titlebarAppearsTransparent)
    w.returnToRepository(from: first.store)
    #expect(!first.showsRepositoryPicker && first.store.commitSubject == "Keep native tab draft")
    try await Task.sleep(for: .milliseconds(300))
    #expect(firstWindow.titlebarAppearsTransparent)
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
    #expect(!tab.showsRepositoryPicker && window.title == tab.title && window.titlebarAppearsTransparent)
    #expect(tab.store.commitSubject == "Keep native navigation draft")
    #expect(w.tabs.count == 1 && f.windows.window(for: tab.id) === window)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test(arguments: [false, true]) @MainActor
func nativeHistoryScrollsBehindTheStatusBar(paginated: Bool) async throws {
    let fixture = try await PreviewFixture.make(commits: 40, branches: 1)
    defer { fixture.clean() }
    let workspace = RepositoryWorkspace(library: fixture.store.library, draftsFile: fixture.root.appendingPathComponent("drafts.json"))
    await workspace.open(await fixture.repository.root)
    let tab = workspace.activeTab
    let windows = NativeRepositoryWindows(workspace: workspace, permitsPresentation: false)
    windows.start()
    defer { windows.stop(); workspace.shutdown() }
    let window = try #require(windows.window(for: tab.id))
    window.setContentSize(NSSize(width: 1200, height: 720))
    let content = try #require(window.contentView)
    let expectedCommits = paginated ? 30 : 40
    tab.store.navigate(.history)
    tab.store.historyOptions.limit = expectedCommits
    tab.store.requestHistory()

    func historyTable(in view: NSView) -> HistoryTableView? {
        if let table = view as? HistoryTableView { return table }
        return view.subviews.lazy.compactMap { historyTable(in: $0) }.first
    }
    for _ in 0..<100 {
        content.layoutSubtreeIfNeeded()
        if let table = historyTable(in: content),
           table.numberOfRows >= expectedCommits,
           let insets = table.enclosingScrollView?.contentView.contentInsets,
           insets.top > 0,
           (insets.bottom > RepositoryStatusBar.height) == paginated { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let table = try #require(historyTable(in: content))
    let scroll = try #require(table.enclosingScrollView)
    let clip = scroll.contentView
    try #require(table.numberOfRows >= expectedCommits)
    #expect(tab.store.historyPresentation.page.hasMore == paginated)
    #expect(!scroll.drawsBackground && table.backgroundColor == .clear)
    let viewport = clip.convert(clip.bounds, to: nil)
    let scrollFrame = scroll.convert(scroll.bounds, to: nil)
    let windowBounds = content.convert(content.bounds, to: nil)
    let statusTop = windowBounds.minY + RepositoryStatusBar.height
    let statusBackdropTop = statusTop + RepositoryStatusBarBackground.featherHeight
    #expect(abs(viewport.minY - windowBounds.minY) < 1)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
        #expect(scroll.subviews.allSatisfy { $0.backgroundFilters.isEmpty })
        func variableBlurs(in view: NSView) -> [VariableBlurNSView] {
            let current = (view as? VariableBlurNSView).map { [$0] } ?? []
            return current + view.subviews.flatMap(variableBlurs)
        }
        let blurs = variableBlurs(in: content)
        let bottomBlur = try #require(blurs.first { blur in
            let frame = blur.convert(blur.bounds, to: nil)
            return abs(frame.minY - windowBounds.minY) < 1 &&
                abs(frame.maxY - statusBackdropTop) < 1 &&
                frame.minX <= viewport.minX + 1 &&
                frame.maxX >= viewport.maxX - 1
        })
        #expect(bottomBlur.isUsingVariableBlurBackdrop)
        let topBlur = try #require(blurs.first { blur in
            let frame = blur.convert(blur.bounds, to: nil)
            return abs(frame.maxY - scrollFrame.maxY) < 1 &&
                abs(frame.minY - (scrollFrame.maxY - clip.contentInsets.top)) < 1 &&
                abs(frame.minX - scrollFrame.minX) < 1 &&
                abs(frame.width - scrollFrame.width) < 1
        })
        #expect(topBlur.isUsingVariableBlurBackdrop)
    }
    let bottomInset = clip.contentInsets.bottom
    #expect(paginated ? bottomInset > RepositoryStatusBar.height : bottomInset == RepositoryStatusBar.height)

    var bounds = clip.bounds
    bounds.origin.y = table.rect(ofRow: 20).midY - bounds.height + RepositoryStatusBar.height / 2
    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
    let passingRow = table.convert(table.rect(ofRow: 20), to: nil)
    #expect(passingRow.midY > windowBounds.minY && passingRow.midY < statusTop)

    bounds.origin.y = table.bounds.maxY
    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
    let lastRow = table.convert(table.rect(ofRow: table.numberOfRows - 1), to: nil)
    #expect(lastRow.minY >= windowBounds.minY + bottomInset - 1)
    if paginated {
        tab.store.loadMoreHistory()
        await tab.store.historyTask?.value
        for _ in 0..<50 {
            content.layoutSubtreeIfNeeded()
            if clip.contentInsets.bottom == RepositoryStatusBar.height { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.store.visibleCommits.count == 40)
        #expect(!tab.store.historyPresentation.page.hasMore)
        #expect(clip.contentInsets.bottom == RepositoryStatusBar.height)
    }
    #expect(!window.isVisible && !NSApp.isActive)
}

@Test @MainActor func nativeSidebarScrollsBehindBothFixedBars() async throws {
    let fixture = try await PreviewFixture.make(commits: 1, branches: 1)
    defer { fixture.clean() }
    let tip = try #require(fixture.tips.first)
    let tags = (1...45).map { "create refs/tags/sidebar-preview-\($0) \(tip)\n" }.joined()
    _ = try await GitProcess.run(["update-ref", "--stdin"], at: fixture.repository.root, input: Data(tags.utf8))
    let workspace = RepositoryWorkspace(library: fixture.store.library, draftsFile: fixture.root.appendingPathComponent("drafts.json"))
    await workspace.open(await fixture.repository.root)
    let windows = NativeRepositoryWindows(workspace: workspace, permitsPresentation: false)
    windows.start()
    defer { windows.stop(); workspace.shutdown() }
    let window = try #require(windows.window(for: workspace.activeTab.id))
    window.setContentSize(NSSize(width: 1200, height: 720))
    let content = try #require(window.contentView)

    func outline(in view: NSView) -> NSOutlineView? {
        if let table = view as? NSOutlineView, table.convert(table.bounds, to: nil).minX < 1 { return table }
        return view.subviews.lazy.compactMap { outline(in: $0) }.first
    }
    for _ in 0..<100 {
        content.layoutSubtreeIfNeeded()
        if let table = outline(in: content), table.numberOfRows >= 45,
           table.enclosingScrollView?.contentView.layer?.mask is CAGradientLayer { break }
        try await Task.sleep(for: .milliseconds(20))
    }

    let table = try #require(outline(in: content))
    try #require(table.numberOfRows >= 45)
    let scroll = try #require(table.enclosingScrollView)
    let clip = scroll.contentView
    let layer = try #require(clip.layer)
    let mask = try #require(layer.mask as? CAGradientLayer)
    #expect(mask.startPoint.y == (clip.isFlipped ? 0 : 1))
    let insets = clip.contentInsets
    let viewport = clip.convert(clip.bounds, to: nil)
    #expect(insets.top > 0 && insets.bottom > RepositoryStatusBar.height)
    #expect(viewport.maxY <= window.contentLayoutRect.maxY + 1)
    #expect(abs(viewport.minY - content.convert(content.bounds, to: nil).minY) < 1)

    var position = clip.bounds
    position.origin.y = table.rect(ofRow: 15).midY - insets.top / 2
    clip.scroll(to: clip.constrainBoundsRect(position).origin)
    let passingRow = table.convert(table.rect(ofRow: 15), to: nil)
    #expect(passingRow.midY > viewport.maxY - insets.top && passingRow.midY < viewport.maxY)
    #expect(layer.mask === mask && mask.frame == layer.bounds)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
        func variableBlurs(in view: NSView) -> [VariableBlurNSView] {
            let current = (view as? VariableBlurNSView).map { [$0] } ?? []
            return current + view.subviews.flatMap(variableBlurs)
        }
        let scrollFrame = scroll.convert(scroll.bounds, to: nil)
        let blurs = variableBlurs(in: content)
        let topBlur = try #require(blurs.first { blur in
            let frame = blur.convert(blur.bounds, to: nil)
            return abs(frame.maxY - viewport.maxY) < 1 &&
                abs(frame.minY - (viewport.maxY - insets.top)) < 1 &&
                abs(frame.minX - scrollFrame.minX) < 1 &&
                abs(frame.width - scrollFrame.width) < 1
        })
        #expect(topBlur.isUsingVariableBlurBackdrop)
        let topBackdrop = try #require(topBlur.layer?.sublayers?.first { NSStringFromClass(type(of: $0)) == "CABackdropLayer" })
        #expect(!topBackdrop.isHidden && (topBackdrop.filters?.count ?? 0) == 1)

        let bottomBlur = try #require(blurs.first { blur in
            let frame = blur.convert(blur.bounds, to: nil)
            return abs(frame.minY - viewport.minY) < 1 &&
                abs(frame.maxY - (viewport.minY + insets.bottom)) < 1 &&
                abs(frame.minX - scrollFrame.minX) < 1 &&
                abs(frame.width - scrollFrame.width) < 1
        })
        #expect(bottomBlur.isUsingVariableBlurBackdrop)
        let bottomBackdrop = try #require(bottomBlur.layer?.sublayers?.first { NSStringFromClass(type(of: $0)) == "CABackdropLayer" })
        #expect(!bottomBackdrop.isHidden && (bottomBackdrop.filters?.count ?? 0) == 1)

        func isOrderedAbove(_ upper: NSView, lower: NSView) -> Bool {
            let upperChain = Array(sequence(first: upper, next: \.superview))
            let lowerChain = Array(sequence(first: lower, next: \.superview))
            guard let shared = upperChain.first(where: { candidate in lowerChain.contains(where: { $0 === candidate }) }),
                  let upperChild = upperChain.first(where: { $0.superview === shared }),
                  let lowerChild = lowerChain.first(where: { $0.superview === shared }),
                  let upperIndex = shared.subviews.firstIndex(of: upperChild),
                  let lowerIndex = shared.subviews.firstIndex(of: lowerChild) else { return false }
            return upperIndex > lowerIndex
        }
        #expect(isOrderedAbove(topBlur, lower: scroll))
        #expect(isOrderedAbove(bottomBlur, lower: scroll))

        let stops = try #require(mask.locations)
        let colors = try #require(mask.colors as? [CGColor])
        let headerEnd = insets.top / viewport.height
        #expect(stops[1].doubleValue < headerEnd / 2)
        #expect((0.12...0.20).contains(colors[1].alpha))
        let shoulder = try #require(stops.lastIndex { $0.doubleValue < headerEnd })
        #expect((0.12...0.20).contains(colors[shoulder].alpha))
        #expect(stops[shoulder + 1].doubleValue > headerEnd)
        #expect(colors[shoulder + 1].alpha == 1)
        let statusStart = 1 - RepositoryStatusBar.height / viewport.height
        let statusStop = try #require(stops.firstIndex { $0.doubleValue > statusStart })
        #expect((0.08...0.24).contains(colors[statusStop].alpha))
    }

    position.origin.y = table.bounds.minY - insets.top
    clip.scroll(to: clip.constrainBoundsRect(position).origin)
    #expect(table.convert(table.rect(ofRow: 0), to: nil).maxY <= viewport.maxY - insets.top + 1)

    position.origin.y = table.rect(ofRow: 32).midY - position.height + RepositoryStatusBar.height / 2
    clip.scroll(to: clip.constrainBoundsRect(position).origin)
    let statusRow = table.convert(table.rect(ofRow: 32), to: nil)
    #expect(statusRow.midY > viewport.minY && statusRow.midY < viewport.minY + RepositoryStatusBar.height)

    position.origin.y = table.bounds.maxY
    clip.scroll(to: clip.constrainBoundsRect(position).origin)
    let lastRow = table.convert(table.rect(ofRow: table.numberOfRows - 1), to: nil)
    #expect(lastRow.minY >= viewport.minY + insets.bottom - 1)
    #expect(!window.isVisible && !NSApp.isActive)
}

@Test @MainActor func nativeWindowCloseProtectsDraftAndKeepsLastRepository() async throws {
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
    #expect(f.windows.controllers.isEmpty && w.tabs.count == 1 && w.activeTab === original)
    #expect(w.drafts.values[try #require(original.root).path]?.subject == "Protect draft from native close")
    f.windows.workspaceChanged()
    #expect(f.windows.controllers.isEmpty)
    f.windows.reopen()
    #expect(f.windows.controllers.count == 1 && w.activeTab === original && !original.showsRepositoryPicker)
    f.windows.window(for: original.id)?.performClose(nil)
    w.showRepositories()
    #expect(f.windows.controllers.count == 1 && w.activeTab === original && original.showsRepositoryPicker)
    let empty = w.newTab()
    #expect(w.close(original.id))
    try #require(f.windows.window(for: empty.id)).performClose(nil)
    #expect(f.windows.controllers.isEmpty && w.activeTab === empty)
    let replacement = w.newTab()
    #expect(w.tabs.count == 1 && w.activeTab === replacement && f.windows.controllers.count == 1)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func closingLastHistoryWindowRestoresItsSelectedCommitOnReopenAndRelaunch() async throws {
    let f = try await NativeTabFixture.make(); defer { f.clean() }
    let workspace = f.workspace, tab = workspace.activeTab, store = tab.store
    let root = try #require(tab.root)
    store.navigate(.history)
    await store.historyTask?.value
    let older = try #require(store.visibleCommits.dropFirst().first)
    store.selectCommit(older)
    await store.detailTask?.value
    let original = try #require(f.windows.window(for: tab.id))
    original.performClose(nil)
    #expect(f.windows.controllers.isEmpty && !tab.showsRepositoryPicker)
    #expect(workspace.session.saved?.tabs.first?.navigation.commitHash == older.hash)
    #expect(workspace.session.saved?.windows.first?.tabs == [tab.id])

    f.windows.reopen()
    let reopened = try #require(f.windows.window(for: tab.id))
    #expect(reopened !== original && workspace.activeStore === store)
    #expect(store.destination == .history && store.selectedCommit?.hash == older.hash)
    #expect(store.historyReveal?.hash == older.hash)

    // Save while the repository window is open, as the app does on Quit.
    workspace.shutdown()
    let relaunched = RepositoryWorkspace(library: workspace.library, draftsFile: workspace.drafts.file)
    let windows = NativeRepositoryWindows(workspace: relaunched, permitsPresentation: false)
    defer { windows.stop(); relaunched.shutdown() }
    windows.holdPresentation()
    windows.start()
    windows.reopen()
    #expect(windows.presentationHeld && windows.controllers.isEmpty)
    await relaunched.restoreSavedSession()
    #expect(windows.presentationHeld && windows.window(for: tab.id) != nil)
    windows.releasePresentation()
    #expect(!relaunched.activeTab.showsRepositoryPicker && relaunched.activeTab.root == root)
    #expect(relaunched.activeStore.destination == .history && relaunched.activeStore.selectedCommit?.hash == older.hash)
    #expect(relaunched.activeStore.historyReveal?.hash == older.hash)
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
