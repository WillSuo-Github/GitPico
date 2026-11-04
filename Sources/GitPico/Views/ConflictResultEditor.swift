import AppKit
import SwiftUI

/// SwiftUI owns the draft; AppKit only owns caret, text undo and reveal scrolling.
struct ConflictResultEditor: NSViewRepresentable {
    @Binding var text: String
    var reveal: String?
    var focusRequest: UUID
    var disabled = false
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textColor = .textColor; editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = true
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = editor.maxSize
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(String(localized: "Conflict resolution result"))
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if editor.string != text {
            let selection = editor.selectedRange()
            context.coordinator.updating = true
            let range = NSRange(location: 0, length: (editor.string as NSString).length)
            if context.coordinator.initialized, editor.shouldChangeText(in: range, replacementString: text) {
                editor.textStorage?.replaceCharacters(in: range, with: text)
                editor.didChangeText()
            } else {
                editor.string = text
                editor.undoManager?.removeAllActions()
            }
            context.coordinator.initialized = true
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            context.coordinator.updating = false
        }
        editor.isEditable = !disabled
        if context.coordinator.lastFocus != focusRequest {
            context.coordinator.lastFocus = focusRequest
            if let reveal {
                let range = (text as NSString).range(of: reveal)
                if range.location != NSNotFound {
                    editor.setSelectedRange(NSRange(location: range.location, length: 0))
                    editor.scrollRangeToVisible(range)
                }
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ConflictResultEditor
        var updating = false
        var initialized = false
        var lastFocus: UUID?
        init(_ parent: ConflictResultEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
