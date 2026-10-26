import AppKit
import Foundation
import GitCore

/// Exercises the real SwiftUI App/menu bootstrap while keeping all repository windows suppressed.
@MainActor enum NativeStartupVerification {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--native-startup-verification") }
    private static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-NativeStartup-" + UUID().uuidString)
    static func makeWorkspace() -> RepositoryWorkspace {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RepositoryWorkspace(library: RepositoryLibrary(file: directory.appendingPathComponent("library.json"), legacy: []), draftsFile: directory.appendingPathComponent("drafts.json"))
    }
    private static func item(named title: String, in menu: NSMenu?) -> NSMenuItem? {
        if let menu { menu.delegate?.menuNeedsUpdate?(menu) }
        menu?.update()
        for item in menu?.items ?? [] {
            if item.title == title { return item }
            if let found = self.item(named: title, in: item.submenu) { return found }
        }
        return nil
    }
    private static func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for child in view.subviews { if let field = searchField(in: child) { return field } }
        return nil
    }
    private static func invoke(_ item: NSMenuItem?) -> Bool {
        guard let item, let menu = item.menu, item.isEnabled else { return false }
        menu.performActionForItem(at: menu.index(of: item))
        return true
    }
    static func finish(_ windows: NativeRepositoryWindows) async {
        try? await Task.sleep(for: .milliseconds(500))
        let workspace = windows.workspace
        let root = directory.appendingPathComponent("MenuContext")
        var repositoryReady = false
        var fixtureError: String?
        do {
            let repository = try await GitRepository.create(at: root)
            let canonicalRoot = await repository.root
            await workspace.open(root)
            repositoryReady = workspace.activeStore.snapshot?.root == canonicalRoot
        } catch { fixtureError = error.localizedDescription }
        try? await Task.sleep(for: .milliseconds(200))
        let repositoryMenuEnabled = item(named: "Refresh", in: NSApp.mainMenu)?.isEnabled == true
        let actionsInvoked = invoke(item(named: "Quick Actions…", in: NSApp.mainMenu))
        try? await Task.sleep(for: .milliseconds(250))
        let search = windows.window(for: workspace.selectedID)?.toolbar?.items.compactMap { $0.view }.compactMap { searchField(in: $0) }.first
        let actionsUseSearch = actionsInvoked && search?.stringValue.trimmingCharacters(in: .whitespaces) == ">"
        let findInvoked = invoke(item(named: "Find…", in: NSApp.mainMenu))
        try? await Task.sleep(for: .milliseconds(200))
        let findUsesSearch = findInvoked && search?.stringValue == workspace.activeStore.search

        let originalID = workspace.selectedID
        let repositoriesInvoked = invoke(item(named: "Repositories", in: NSApp.mainMenu))
        try? await Task.sleep(for: .milliseconds(200))
        let repositoriesReused = repositoriesInvoked && workspace.tabs.count == 1 && workspace.selectedID == originalID && workspace.activeTab.showsRepositoryPicker && windows.window(for: originalID)?.tabGroup?.isTabBarVisible == false
        let pickerMenuDisabled = item(named: "Refresh", in: NSApp.mainMenu)?.isEnabled == false
        await workspace.open(root)
        try? await Task.sleep(for: .milliseconds(200))
        let initialCount = workspace.tabs.count
        let singleTabBarHidden = windows.window(for: workspace.selectedID)?.tabGroup?.isTabBarVisible == false
        let newItem = item(named: "New Tab", in: NSApp.mainMenu)
        let newInvoked = invoke(newItem)
        try? await Task.sleep(for: .milliseconds(200))
        let newWorks = workspace.tabs.count == initialCount + 1 && windows.controllers.count == workspace.tabs.count
        let multipleTabBarVisible = windows.window(for: workspace.selectedID)?.tabGroup?.isTabBarVisible == true
        let chooserMenuDisabled = item(named: "Refresh", in: NSApp.mainMenu)?.isEnabled == false
        let closeItem = item(named: "Close Tab", in: NSApp.mainMenu)
        let closeInvoked = invoke(closeItem)
        try? await Task.sleep(for: .milliseconds(200))
        let returnedMenuEnabled = item(named: "Refresh", in: NSApp.mainMenu)?.isEnabled == true
        let active = windows.window(for: workspace.selectedID)
        let report: [String: Any] = [
            "nativeStartupVerification": true,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "isActive": NSApp.isActive,
            "visibleWindows": NSApp.windows.filter(\.isVisible).count,
            "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
            "frontmostProcessIdentifier": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            "menuTitles": NSApp.mainMenu?.items.map(\.title) ?? [],
            "newTabShortcut": newItem?.keyEquivalent ?? "missing",
            "closeTabShortcut": closeItem?.keyEquivalent ?? "missing",
            "newTabMenuWorks": newInvoked && newWorks,
            "closeTabMenuWorks": closeInvoked && workspace.tabs.count == initialCount,
            "repositoryMenuContextWorks": repositoryReady && repositoryMenuEnabled && chooserMenuDisabled && returnedMenuEnabled,
            "repositoriesMenuReusesCurrentTab": repositoriesReused && pickerMenuDisabled && workspace.tabs.count == 1,
            "quickActionsUseToolbarSearch": actionsUseSearch,
            "findUsesToolbarSearch": findUsesSearch,
            "repositoryOpenSeconds": workspace.activeStore.lastOpenReport?.seconds ?? -1,
            "repositoryOpenPhases": workspace.activeStore.lastOpenReport?.phases.map { ["name": $0.name, "seconds": $0.seconds] as [String: Any] } ?? [],
            "repositoryReady": repositoryReady,
            "repositoryMenuEnabled": repositoryMenuEnabled,
            "chooserMenuDisabled": chooserMenuDisabled,
            "returnedMenuEnabled": returnedMenuEnabled,
            "fixtureError": fixtureError ?? "",
            "nativeTabBarVisible": active?.tabGroup?.isTabBarVisible ?? false,
            "singleTabBarHidden": singleTabBarHidden,
            "multipleTabBarVisible": multipleTabBarVisible,
            "singleTabBarHiddenAfterClose": active?.tabGroup?.isTabBarVisible == false,
            "nativeSelectionMatchesModel": active != nil && active?.tabGroup?.selectedWindow === active,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ]
        windows.stop()
        workspace.shutdown()
        try? FileManager.default.removeItem(at: directory)
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--verification-output"), args.indices.contains(index + 1),
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
        }
        if args.contains("--verification-exit") { NSApp.terminate(nil) }
    }
}
