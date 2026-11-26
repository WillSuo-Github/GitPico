import AppKit

/// AppKit owns tab chrome and responder actions; Git state remains in RepositoryWorkspace.
final class RepositoryNativeWindow: NSWindow {
    private static let transparentTitlebarDoubleClickSetter = NSSelectorFromString("setTitlebarHandlesDoubleClickWhenTransparent:")
    let tabID: UUID
    let permitsPresentation: Bool
    weak var repositoryWindows: NativeRepositoryWindows?
    weak var pickerSearchField: RepositoryPickerSearchControl?
    private var repositoryDropEnabled = false
    private(set) var usesNativeTransparentTitlebarDoubleClick = false
    private var pendingFallbackTitlebarDoubleClick: (location: NSPoint, windowOrigin: NSPoint)?
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
        configureTransparentTitlebarDoubleClick()
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
        if !usesNativeTransparentTitlebarDoubleClick, titlebarAppearsTransparent, handleFallbackTitlebarDoubleClick(event) {
            return
        }
        super.sendEvent(event)
    }

    func setRepositoryDropEnabled(_ enabled: Bool) {
        guard enabled != repositoryDropEnabled else { return }
        repositoryDropEnabled = enabled
        if enabled { registerForDraggedTypes([.fileURL]) }
        else { unregisterDraggedTypes() }
    }

    private func configureTransparentTitlebarDoubleClick() {
        guard responds(to: Self.transparentTitlebarDoubleClickSetter) else { return }
        setValue(true, forKey: "titlebarHandlesDoubleClickWhenTransparent")
        usesNativeTransparentTitlebarDoubleClick = true
    }

    private func handleFallbackTitlebarDoubleClick(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            if event.clickCount == 2,
               canHandleFallbackTitlebarDoubleClick(at: event.locationInWindow, modifiers: event.modifierFlags) {
                pendingFallbackTitlebarDoubleClick = (event.locationInWindow, frame.origin)
            } else {
                pendingFallbackTitlebarDoubleClick = nil
            }
            return false
        case .leftMouseUp:
            guard let pending = pendingFallbackTitlebarDoubleClick else { return false }
            pendingFallbackTitlebarDoubleClick = nil
            let deltaX = event.locationInWindow.x - pending.location.x
            let deltaY = event.locationInWindow.y - pending.location.y
            guard frame.origin == pending.windowOrigin,
                  hypot(deltaX, deltaY) <= 6,
                  canHandleFallbackTitlebarDoubleClick(at: event.locationInWindow, modifiers: event.modifierFlags) else {
                return false
            }
            performFallbackTitlebarDoubleClickAction()
            return true
        case .leftMouseDragged, .rightMouseDown, .otherMouseDown, .keyDown:
            pendingFallbackTitlebarDoubleClick = nil
            return false
        default:
            return false
        }
    }

    func canHandleFallbackTitlebarDoubleClick(at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard attachedSheet == nil,
              !styleMask.contains(.fullScreen),
              modifiers.intersection([.command, .control, .shift]).isEmpty,
              point.y >= contentLayoutRect.maxY,
              point.y <= frame.height - 4,
              let contentView,
              let themeFrame = contentView.superview,
              let hitView = themeFrame.hitTest(point),
              hitView.isDescendant(of: contentView) else {
            return false
        }
        var currentView: NSView? = hitView
        while let view = currentView {
            if !view.mouseDownCanMoveWindow || view is NSControl || view is NSText { return false }
            if view === contentView { break }
            currentView = view.superview
        }
        return true
    }

    func performFallbackTitlebarDoubleClickAction(preference: String? = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) {
        switch preference ?? "Fill" {
        case "None":
            return
        case "Minimize":
            performMiniaturize(nil)
        default:
            performZoom(nil)
        }
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
