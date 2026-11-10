import AppKit

/// AppKit owns tab chrome and responder actions; Git state remains in RepositoryWorkspace.
final class RepositoryNativeWindow: NSWindow {
    let tabID: UUID
    let permitsPresentation: Bool
    weak var repositoryWindows: NativeRepositoryWindows?
    weak var pickerSearchField: RepositoryPickerSearchControl?
    private var repositoryDropEnabled = false
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
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, pickerSearchField?.beginSearching(with: event) == true { return }
        super.sendEvent(event)
    }

    func setRepositoryDropEnabled(_ enabled: Bool) {
        guard enabled != repositoryDropEnabled else { return }
        repositoryDropEnabled = enabled
        if enabled { registerForDraggedTypes([.fileURL]) }
        else { unregisterDraggedTypes() }
    }
}

final class RepositoryWindowController: NSWindowController, NSWindowDelegate, NSDraggingDestination {
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
    func windowDidMove(_ notification: Notification) { repositoryWindows?.workspace.scheduleSessionSave() }
    func windowDidResize(_ notification: Notification) { repositoryWindows?.workspace.scheduleSessionSave() }

    private func repositoryDropTab(_ sender: any NSDraggingInfo) -> RepositoryTab? {
        guard let window = window as? RepositoryNativeWindow, sender.draggingDestinationWindow === window,
              window.attachedSheet == nil, sender.draggingSourceOperationMask.contains(.copy),
              let tab = repositoryWindows?.workspace.tabs.first(where: { $0.id == window.tabID }),
              tab.acceptsRepositoryDrops else { return nil }
        return tab
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard repositoryDropTab(sender) != nil, sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) else { return [] }
        return .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { draggingEntered(sender) == .copy }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let tab = repositoryDropTab(sender),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        return tab.addDroppedRepositories(urls)
    }
}
