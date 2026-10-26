import AppKit
import SwiftUI

struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var focusRequest: UUID?
    var selectAllOnFocus = true
    var session: ToolbarSearchSession? = nil
    var presentation: ToolbarSearchPresentation? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusRequest: $focusRequest) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = SearchControl()
        field.onClick = { [weak coordinator = context.coordinator] in coordinator?.beginEditing() }
        field.delegate = context.coordinator; field.controlSize = .regular
        field.sendsSearchStringImmediately = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.postsFrameChangedNotifications = true
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text; coordinator.focusRequest = $focusRequest; coordinator.selectAllOnFocus = selectAllOnFocus
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !composing, field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder; field.isEnabled = context.environment.isEnabled
        field.setAccessibilityLabel("Search files, branches, commits and actions")
        coordinator.update(field, session: session, presentation: presentation)
        coordinator.focus(field, request: focusRequest)
    }
    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) { coordinator.stop(); field.delegate = nil }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var lastFocusRequest: UUID?
        var focusRequest: Binding<UUID?>
        var selectAllOnFocus = true
        private(set) var panel: NSPanel?
        private weak var field: NSSearchField?
        private var session: ToolbarSearchSession?
        private var presentation: ToolbarSearchPresentation?
        private var eventMonitor: Any?
        private var observers: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?

        init(text: Binding<String>, focusRequest: Binding<UUID?> = .constant(nil)) { self.text = text; self.focusRequest = focusRequest }
        func focus(_ field: NSSearchField, request: UUID?) {
            guard request != lastFocusRequest else { return }
            lastFocusRequest = request
            guard let request else { return }
            Task { @MainActor [weak field, weak self] in
                guard let field, let self, field.isEnabled, self.lastFocusRequest == request, self.focusRequest.wrappedValue == request, let window = field.window else { return }
                window.makeFirstResponder(field)
                if self.selectAllOnFocus { field.selectText(nil) }
                else if let editor = field.currentEditor() as? NSTextView { editor.setSelectedRange(NSRange(location: field.stringValue.utf16.count, length: 0)) }
            }
        }
        func update(_ field: NSSearchField, session: ToolbarSearchSession?, presentation: ToolbarSearchPresentation?) {
            if self.session !== session { closePanel(); panel = nil }
            self.field = field; self.session = session; self.presentation = presentation
            if presentation?.executing == true { closePanel(); field.window?.makeFirstResponder(nil); return }
            guard field.isEnabled, presentation?.visible == true else { closePanel(); return }
            showPanel()
        }
        func beginEditing() { session?.beginEditing() }
        func controlTextDidBeginEditing(_ notification: Notification) { beginEditing() }
        func controlTextDidEndEditing(_ notification: Notification) { session?.endEditing(); closePanel() }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            if session?.focused == false { session?.beginEditing() }
            text.wrappedValue = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText(), let session else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)): session.move(1); return true
            case #selector(NSResponder.moveUp(_:)): session.move(-1); return true
            case #selector(NSResponder.insertNewline(_:)): return session.submit()
            case #selector(NSResponder.cancelOperation(_:)):
                guard session.visible || session.actionsOnly else { return false }
                session.cancel(); closePanel(); return true
            default: return false
            }
        }
        func stop() { session?.stop(); closePanel(); panel = nil; session = nil; field = nil }
        private func showPanel() {
            guard let field, let window = field.window, let state = presentation,
                  NSApp.isActive, window.isKeyWindow, window.isVisible, !field.isHiddenOrHasHiddenAncestor,
                  (window as? RepositoryNativeWindow)?.permitsPresentation != false,
                  (field.currentEditor() as? NSTextView) != nil, let session else { closePanel(); return }
            if panel == nil {
                let panel = SearchSuggestionsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
                panel.hasShadow = true; panel.hidesOnDeactivate = true; panel.level = .popUpMenu
                panel.contentViewController = NSHostingController(rootView: ToolbarSearchSuggestions(session: session))
                self.panel = panel
            }
            guard let panel else { return }
            let fieldRect = window.convertToScreen(field.convert(field.bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? fieldRect.insetBy(dx: -500, dy: -500)
            let width = min(560, screen.width - 16), height = min(max(150, state.height), screen.height - 32)
            let x = min(max(screen.minX + 8, fieldRect.maxX - width), screen.maxX - width - 8)
            let y = max(screen.minY + 8, fieldRect.minY - height - 6)
            let frame = NSRect(x: x, y: y, width: width, height: height)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            if panel.parent !== window { panel.parent?.removeChildWindow(panel); window.addChildWindow(panel, ordered: .above) }
            panel.orderFront(nil)
            installObservers(window, field: field)
        }
        private func installObservers(_ window: NSWindow, field: NSSearchField) {
            guard observedWindow !== window else { return }
            removeObservers(); observedWindow = window
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSView.frameDidChangeNotification] {
                observers.append(center.addObserver(forName: name, object: name == NSView.frameDidChangeNotification ? field : window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.showPanel() }
                })
            }
            for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject), (NSWindow.willCloseNotification, window as AnyObject), (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.session?.endEditing(); self?.closePanel() }
                })
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let insideField = event.window === self.field?.window && self.field.map { $0.convert($0.bounds, to: nil).contains(event.locationInWindow) } == true
                    if event.window !== self.panel, !insideField { self.session?.dismiss(); self.closePanel() }
                }
                return event
            }
        }
        private func closePanel() {
            if let panel { panel.orderOut(nil); panel.parent?.removeChildWindow(panel) }
            removeObservers()
        }
        private func removeObservers() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll(); observedWindow = nil
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        }
    }
}

private final class SearchSuggestionsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SearchControl: NSSearchField {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event); onClick?() }
}
