import AppKit
import SwiftUI
import Testing
@testable import GitPico

/// Keep the active user's input source unchanged while observing the forwarded native event.
@MainActor private final class PickerRecordingEditor: NSTextView {
    var events: [NSEvent] = []
    override func keyDown(with event: NSEvent) {
        events.append(event)
        insertText(event.characters ?? "", replacementRange: selectedRange())
    }
}

@MainActor private final class PickerEditorDelegate: NSObject, NSWindowDelegate {
    let editor = PickerRecordingEditor()
    override init() { super.init(); editor.isFieldEditor = true }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { editor }
}

@MainActor private struct PickerTypingFixture {
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    let field = RepositoryPickerSearchControl()
    let list = NSTableView()
    let other = NSTextField()
    let delegate = PickerEditorDelegate()
    init() {
        window.delegate = delegate
        let root = NSStackView(views: [field, other, list]); root.orientation = .vertical
        window.contentView = root
    }
    func event(_ text: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: text,
                                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
    }
    func clean() { window.contentView = nil; window.close() }
}

@Test @MainActor func pickerTypingFocusesSearchAndForwardsFirstCharacterExactlyOnce() throws {
    let f = PickerTypingFixture(); defer { f.clean() }
    #expect(f.window.pickerSearchField === f.field)
    f.field.stringValue = "git"
    #expect(f.window.makeFirstResponder(f.list))
    let event = try f.event("P", modifiers: .shift)
    f.window.sendEvent(event)
    #expect(f.delegate.editor.events.count == 1 && f.delegate.editor.events.first === event)
    #expect(f.field.currentEditor() === f.delegate.editor)
    #expect(f.delegate.editor.string == "gitP")
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
    f.field.removeFromSuperview()
    #expect(f.window.pickerSearchField == nil)
}

@Test @MainActor func pickerTypingLeavesEditingShortcutsNavigationAndOtherWindowsAlone() async throws {
    let f = PickerTypingFixture(); defer { f.clean() }
    #expect(f.window.makeFirstResponder(f.list))
    for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .function] {
        #expect(!f.field.beginSearching(with: try f.event("a", modifiers: modifier)))
    }
    for key in ["\r", "\t", "\u{1b}", "\u{7f}", "\u{f700}", "\u{f704}", " ", ""] {
        #expect(!f.field.beginSearching(with: try f.event(key)))
    }
    #expect(f.window.makeFirstResponder(f.other))
    #expect(!f.field.beginSearching(with: try f.event("a")))
    #expect(f.other.currentEditor() === f.delegate.editor)
    #expect(f.delegate.editor.events.isEmpty)
    var wantsInitialFocus = true
    let coordinator = RepositoryPickerSearchField.Coordinator(text: .constant(""),
        isFocused: Binding(get: { wantsInitialFocus }, set: { wantsInitialFocus = $0 }), submit: {})
    coordinator.requestFocus(f.field)
    await coordinator.focusTask?.value
    #expect(f.other.currentEditor() === f.delegate.editor && !wantsInitialFocus)
    #expect(f.window.makeFirstResponder(f.list))
    f.field.isEnabled = false
    #expect(!f.field.beginSearching(with: try f.event("a")))
    f.field.isEnabled = true; f.field.isHidden = true
    #expect(!f.field.beginSearching(with: try f.event("a")))
    f.field.isHidden = false
    let second = PickerTypingFixture(); defer { second.clean() }
    #expect(!f.field.beginSearching(with: try second.event("a")))
}

@Test @MainActor func pickerSearchPublishesCommittedTextAndDoesNotSubmitMarkedInput() throws {
    let f = PickerTypingFixture(); defer { f.clean() }
    var query = "", focused = false, submissions = 0
    let coordinator = RepositoryPickerSearchField.Coordinator(
        text: Binding(get: { query }, set: { query = $0 }),
        isFocused: Binding(get: { focused }, set: { focused = $0 }), submit: { submissions += 1 })
    f.field.delegate = coordinator
    #expect(f.window.makeFirstResponder(f.field))
    let editor = try #require(f.field.currentEditor() as? NSTextView)
    editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.hasMarkedText())
    coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: f.field))
    #expect(query.isEmpty)
    #expect(!coordinator.control(f.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(submissions == 0)
    editor.insertText("你好", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    editor.unmarkText()
    coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: f.field))
    #expect(query == "你好")
    #expect(coordinator.control(f.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(submissions == 1)
    #expect(f.window.makeFirstResponder(f.list))
    #expect(!focused)
}

@Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
@MainActor func pickerPageTypingFiltersRepositoryNamesAfterLeavingSearch(direction: LayoutDirection) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-picker-typing-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: [])
    for name in ["Alpha", "Beta"] {
        let path = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        _ = try library.recordOpened(path)
    }
    let workspace = RepositoryWorkspace(library: library, draftsFile: root.appendingPathComponent("drafts.json"))
    let window = RepositoryNativeWindow(tabID: workspace.activeTab.id, permitsPresentation: false)
    let delegate = PickerEditorDelegate(); window.delegate = delegate
    window.contentView = NSHostingView(rootView: RepositoryPickerView(workspace: workspace, tab: workspace.activeTab, showsSidebar: false).environment(\.layoutDirection, direction))
    defer { window.contentView = nil; window.close(); workspace.shutdown() }
    let deadline = ContinuousClock.now + .seconds(5)
    while window.pickerSearchField == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let field = try #require(window.pickerSearchField)
    #expect(field.alignment == (direction == .rightToLeft ? NSTextAlignment.right : .left))
    #expect(window.makeFirstResponder(nil))
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: "B",
                                            charactersIgnoringModifiers: "B", isARepeat: false, keyCode: 11))
    window.sendEvent(event)
    #expect(delegate.editor.events.first === event)
    #expect(workspace.activeTab.pickerQuery == "B")
    for character in ["e", "t", "a"] {
        let next = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: character,
                                               charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0))
        window.sendEvent(next)
    }
    #expect(delegate.editor.events.count == 4 && workspace.activeTab.pickerQuery == "Beta")
    #expect(library.matches(query: workspace.activeTab.pickerQuery, filter: workspace.activeTab.pickerFilter).map(\.name) == ["Beta"])
    #expect(field.currentEditor() === delegate.editor)
    if let capture = ProcessInfo.processInfo.environment["GITPICO_PICKER_TYPING_CAPTURE"] {
        window.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(200))
        let view = try #require(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: capture)
        let target = direction == .rightToLeft ? output.deletingPathExtension().appendingPathExtension("rtl.png") : output
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: target)
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
