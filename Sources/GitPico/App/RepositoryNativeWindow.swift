import AppKit

/// AppKit owns tab chrome and responder actions; Git state remains in RepositoryWorkspace.
final class RepositoryNativeWindow: NSWindow {
    let tabID: UUID
    let permitsPresentation: Bool
    weak var repositoryWindows: NativeRepositoryWindows?
    init(tabID: UUID, permitsPresentation: Bool) {
        self.tabID = tabID
        self.permitsPresentation = permitsPresentation
        // NavigationSplitView needs the window's titlebar safe area to position its materials.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1420, height: 900),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        tabbingMode = .automatic
        tabbingIdentifier = "com.willsuo.GitPico.repositories"
        toolbarStyle = .unified
        titleVisibility = .hidden
        contentMinSize = NSSize(width: 1080, height: 680)
    }
    override var canBecomeKey: Bool { permitsPresentation && super.canBecomeKey }
    override var canBecomeMain: Bool { permitsPresentation && super.canBecomeMain }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if permitsPresentation || place == .out { super.order(place, relativeTo: otherWin) }
    }
    override func orderFront(_ sender: Any?) { if permitsPresentation { super.orderFront(sender) } }
    override func orderBack(_ sender: Any?) { if permitsPresentation { super.orderBack(sender) } }
    override func orderFrontRegardless() { if permitsPresentation { super.orderFrontRegardless() } }
    override func makeKeyAndOrderFront(_ sender: Any?) { if permitsPresentation { super.makeKeyAndOrderFront(sender) } }
    override func newWindowForTab(_ sender: Any?) { repositoryWindows?.newTab(from: tabID) }
}

final class RepositoryWindowController: NSWindowController, NSWindowDelegate {
    weak var repositoryWindows: NativeRepositoryWindows?
    override func newWindowForTab(_ sender: Any?) { window?.newWindowForTab(sender) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let window = sender as? RepositoryNativeWindow else { return true }
        return repositoryWindows?.shouldClose(window) ?? true
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? RepositoryNativeWindow else { return }
        repositoryWindows?.didClose(window)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? RepositoryNativeWindow else { return }
        repositoryWindows?.didSelect(window)
    }
}
