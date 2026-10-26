import AppKit
import SwiftUI

@MainActor final class NativeRepositoryWindows: RepositoryWindowRouting {
    let workspace: RepositoryWorkspace
    let permitsPresentation: Bool
    private(set) var controllers: [UUID: RepositoryWindowController] = [:]
    private var observers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var membershipObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var nativeClosing: Set<UUID> = []
    private var closedChoosers: Set<UUID> = []
    private var synchronizing = false
    private var needsSynchronization = false
    private var stopping = false
    private var lastSelectedID: UUID?
    private var preparedAnchorID: UUID?
    var hasRepositoryWindows: Bool { !controllers.isEmpty }

    init(workspace: RepositoryWorkspace, permitsPresentation: Bool = true) {
        self.workspace = workspace
        self.permitsPresentation = permitsPresentation
    }
    func start() {
        workspace.windowRouting = self
        workspaceChanged()
    }
    func stop() {
        stopping = true
        workspace.windowRouting = nil
        observers.removeAll()
        membershipObservers.removeAll()
        let windows = controllers.values.compactMap(\.window)
        controllers.removeAll()
        for window in windows { window.delegate = nil; window.close() }
    }
    func window(for id: UUID) -> RepositoryNativeWindow? { controllers[id]?.window as? RepositoryNativeWindow }
    func prepareNewTab(from id: UUID) { preparedAnchorID = id }
    func newTab(from id: UUID) {
        workspace.newTab(from: id)
    }
    func reopen() {
        closedChoosers.remove(workspace.selectedID)
        workspaceChanged()
    }
    func workspaceChanged() {
        guard !stopping else { return }
        if synchronizing { needsSynchronization = true; return }
        repeat {
            needsSynchronization = false
            synchronizing = true
            reconcile()
            synchronizing = false
        } while needsSynchronization
    }
    private func reconcile() {
        closedChoosers.remove(workspace.selectedID)
        if workspace.tabs.count > 1 {
            for id in closedChoosers {
                if let tab = workspace.tabs.first(where: { $0.id == id }), tab.root == nil, !tab.isBusy { _ = workspace.close(id) }
            }
        }
        let ids = Set(workspace.tabs.map(\.id))
        closedChoosers.formIntersection(ids)
        for id in Array(controllers.keys) where !ids.contains(id) && !nativeClosing.contains(id) {
            let controller = controllers.removeValue(forKey: id)
            controller?.window?.delegate = nil
            controller?.window?.close()
        }
        var anchor = (preparedAnchorID ?? lastSelectedID).flatMap { window(for: $0) }
        preparedAnchorID = nil
        if anchor == nil || nativeClosing.contains(anchor!.tabID) {
            anchor = controllers.keys.filter { !nativeClosing.contains($0) }.compactMap { window(for: $0) }.first
        }
        for tab in workspace.tabs where controllers[tab.id] == nil && !closedChoosers.contains(tab.id) {
            let window = makeWindow(tab)
            if let anchor, anchor !== window { anchor.addTabbedWindow(window, ordered: .above) }
            else { anchor = window }
        }
        observeGroups()
        if let window = window(for: workspace.selectedID), !nativeClosing.contains(window.tabID) {
            lastSelectedID = window.tabID
            if window.tabGroup?.selectedWindow !== window { window.tabGroup?.selectedWindow = window }
            if permitsPresentation, !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        }
    }
    private func makeWindow(_ tab: RepositoryTab) -> RepositoryNativeWindow {
        let window = RepositoryNativeWindow(tabID: tab.id, permitsPresentation: permitsPresentation)
        window.repositoryWindows = self
        let content = RepositoryWorkspaceView(workspace: workspace, tab: tab, presentsAlerts: permitsPresentation) { [weak self] in
            self?.updateDescriptor(tab.id)
        }
        window.contentViewController = NSHostingController(rootView: content)
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1420, height: 900)), display: false)
        if permitsPresentation {
            if let source = lastSelectedID.flatMap({ self.window(for: $0) }) { window.setFrame(source.frame, display: false) }
            else {
                if !window.setFrameUsingName("GitPico.RepositoryWindow") { window.center() }
                _ = window.setFrameAutosaveName("GitPico.RepositoryWindow")
            }
        } else { window.setFrameOrigin(NSPoint(x: -10000, y: -10000)) }
        let controller = RepositoryWindowController(window: window)
        controller.repositoryWindows = self
        window.delegate = controller
        controllers[tab.id] = controller
        updateDescriptor(tab.id)
        DispatchQueue.main.async { [weak self] in self?.updateDescriptor(tab.id) }
        return window
    }
    func updateDescriptor(_ id: UUID) {
        guard let tab = workspace.tabs.first(where: { $0.id == id }), let window = window(for: id) else { return }
        let title = tab.root == nil ? "Repositories" : tab.title
        window.title = title
        window.tab.title = title
        window.tab.toolTip = tab.showsRepositoryPicker ? "Choose a repository" : (tab.root?.path ?? "Choose a repository")
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: tab.showsRepositoryPicker ? "square.grid.2x2" : "folder", accessibilityDescription: nil)
        attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
        let label = NSMutableAttributedString(attachment: attachment)
        label.append(NSAttributedString(string: "  " + title))
        window.tab.attributedTitle = label
        if tab.isBusy {
            if window.tab.accessoryView == nil {
                let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
                progress.style = .spinning; progress.controlSize = .small
                progress.startAnimation(nil)
                window.tab.accessoryView = progress
                progress.widthAnchor.constraint(equalToConstant: 14).isActive = true
                progress.heightAnchor.constraint(equalToConstant: 14).isActive = true
            }
        } else { window.tab.accessoryView = nil }
        window.toolbar?.displayMode = .iconOnly
        // The titlebar background draws an opaque band over the picker's gradient; repository pages keep it for their scroll-edge effect.
        window.titlebarAppearsTransparent = tab.showsRepositoryPicker || tab.store.snapshot == nil
        if let content = window.contentViewController { configureContentLayout(content) }
    }
    private func configureContentLayout(_ controller: NSViewController) {
        if let split = controller as? NSSplitViewController {
            for item in split.splitViewItems where item.behavior == .sidebar { item.allowsFullHeightLayout = false }
        }
        for child in controller.children { configureContentLayout(child) }
    }
    private func observeGroups() {
        let groups = controllers.keys.compactMap { window(for: $0)?.tabGroup }
        let ids = Set(groups.map(ObjectIdentifier.init))
        observers = observers.filter { ids.contains($0.key) }
        membershipObservers = membershipObservers.filter { ids.contains($0.key) }
        for group in groups where observers[ObjectIdentifier(group)] == nil {
            let id = ObjectIdentifier(group)
            observers[id] = group.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.selectionChanged(in: id)
                }
            }
            membershipObservers[id] = group.observe(\.windows, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.membershipChanged() }
            }
        }
        for group in groups { updateTabBarVisibility(group) }
    }
    private func membershipChanged() {
        guard !stopping else { return }
        observeGroups()
    }
    private func updateTabBarVisibility(_ group: NSWindowTabGroup) {
        let shouldShow = group.windows.count > 1
        guard group.isTabBarVisible != shouldShow,
              let window = group.selectedWindow ?? group.windows.first else { return }
        window.toggleTabBar(nil)
    }
    private func selectionChanged(in id: ObjectIdentifier) {
        guard let group = controllers.keys.compactMap({ window(for: $0)?.tabGroup }).first(where: { ObjectIdentifier($0) == id }),
              let selected = group.selectedWindow as? RepositoryNativeWindow else { return }
        didSelect(selected)
    }
    func didSelect(_ window: RepositoryNativeWindow) {
        guard !stopping, !synchronizing, controllers[window.tabID] != nil else { return }
        lastSelectedID = window.tabID
        observeGroups()
        if workspace.selectedID != window.tabID { workspace.select(window.tabID) }
    }
    func cycleNativeTabs(_ offset: Int) -> Bool {
        guard let window = window(for: workspace.selectedID), let group = window.tabGroup else { return false }
        let ids = group.windows.compactMap { ($0 as? RepositoryNativeWindow)?.tabID }
        guard let index = ids.firstIndex(of: workspace.selectedID), !ids.isEmpty else { return false }
        workspace.select(ids[(index + offset % ids.count + ids.count) % ids.count])
        return true
    }
    func shouldClose(_ window: RepositoryNativeWindow) -> Bool {
        guard let tab = workspace.tabs.first(where: { $0.id == window.tabID }) else { return true }
        if workspace.tabs.count == 1, tab.root == nil, !tab.isBusy {
            closedChoosers.insert(tab.id)
            return true
        }
        nativeClosing.insert(tab.id)
        let result = workspace.close(tab.id)
        nativeClosing.remove(tab.id)
        return result
    }
    func didClose(_ window: RepositoryNativeWindow) {
        controllers.removeValue(forKey: window.tabID)
        guard !stopping, !closedChoosers.contains(window.tabID) else { return }
        if workspace.tabs.contains(where: { $0.id == window.tabID }) { _ = workspace.close(window.tabID) }
        workspaceChanged()
    }
}
