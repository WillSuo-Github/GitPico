import AppKit
import SwiftUI

/// SwiftUI owns the query; AppKit forwards the initiating event through the native text input system.
struct RepositoryPickerSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, isFocused: $isFocused, submit: submit) }
    func makeNSView(context: Context) -> RepositoryPickerSearchControl {
        let field = RepositoryPickerSearchControl()
        field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = String(localized: "Search name, path or group")
        field.setAccessibilityLabel(field.placeholderString)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.didAttach = { [weak coordinator = context.coordinator, weak field] in
            if let field { coordinator?.requestFocus(field) }
        }
        return field
    }
    func updateNSView(_ field: RepositoryPickerSearchControl, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text; coordinator.isFocused = $isFocused; coordinator.submit = submit
        field.isEnabled = context.environment.isEnabled
        let alignment: NSTextAlignment = context.environment.layoutDirection == .rightToLeft ? .right : .left
        if field.alignment != alignment { field.alignment = alignment }
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != text { field.stringValue = text }
        if isFocused != coordinator.requestedFocus {
            coordinator.requestedFocus = isFocused
            coordinator.requestFocus(field)
        }
    }
    static func dismantleNSView(_ field: RepositoryPickerSearchControl, coordinator: Coordinator) {
        coordinator.focusTask?.cancel(); field.didAttach = nil; field.delegate = nil; field.unregister()
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var submit: () -> Void
        var requestedFocus = false
        var focusTask: Task<Void, Never>?
        init(text: Binding<String>, isFocused: Binding<Bool>, submit: @escaping () -> Void) {
            self.text = text; self.isFocused = isFocused; self.submit = submit
        }
        func requestFocus(_ field: NSTextField) {
            focusTask?.cancel()
            guard isFocused.wrappedValue else { return }
            focusTask = Task { @MainActor [weak self, weak field] in
                await Task.yield()
                guard !Task.isCancelled, let self, self.isFocused.wrappedValue, let field,
                      field.isEnabled, let window = field.window, window.attachedSheet == nil,
                      NSApp.modalWindow == nil else { return }
                if field.currentEditor() == nil {
                    guard !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else {
                        self.isFocused.wrappedValue = false; return
                    }
                    window.makeFirstResponder(field)
                }
            }
        }
        func controlTextDidBeginEditing(_ notification: Notification) { isFocused.wrappedValue = true }
        func controlTextDidEndEditing(_ notification: Notification) { isFocused.wrappedValue = false }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            text.wrappedValue = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            submit(); return true
        }
    }
}

final class RepositoryPickerSearchControl: NSTextField {
    private weak var registeredWindow: RepositoryNativeWindow?
    var didAttach: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unregister()
        if let window = window as? RepositoryNativeWindow {
            registeredWindow = window
            window.pickerSearchField = self
        }
        if window != nil { didAttach?() }
    }
    func unregister() {
        if registeredWindow?.pickerSearchField === self { registeredWindow?.pickerSearchField = nil }
        registeredWindow = nil
    }
    func beginSearching(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window, event.windowNumber == window.windowNumber,
              isEnabled, isEditable, !isHiddenOrHasHiddenAncestor, window.attachedSheet == nil,
              NSApp.modalWindow == nil,
              event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty,
              let characters = event.characters, characters.rangeOfCharacter(from: .alphanumerics) != nil else { return false }
        // Editing anywhere else (including marked IME text) already has an input destination.
        guard !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return false }
        guard window.makeFirstResponder(self), let editor = currentEditor() as? NSTextView else { return false }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.keyDown(with: event)
        return true
    }
}
