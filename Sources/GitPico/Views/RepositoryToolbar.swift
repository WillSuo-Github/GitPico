import AppKit
import GitCore
import SwiftUI

struct RepositoryToolbar: ToolbarContent {
    @Bindable var store: RepositoryStore
    var body: some ToolbarContent {
        if store.snapshot == nil {
            ToolbarItem(placement: .navigation) { RepositoryMenu(store: store) }
        }
        if let snapshot = store.snapshot {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: store.goBack) { Label("Previous", systemImage: "chevron.left") }.disabled(store.backStack.isEmpty || store.isBusy)
                Button(action: store.goForward) { Label("Next", systemImage: "chevron.right") }.disabled(store.forwardStack.isEmpty || store.isBusy)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.showingQuickActions = true } label: { Label("Quick Actions", systemImage: "wand.and.stars") }
                    .help("Quick Actions (⌘⇧A)").disabled(store.isBusy)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let record = store.undoAvailability?.undo { store.recoveryRequest = RecoveryRequest(action: .undo(record, false)) }
                } label: { Label("Undo Git Operation", systemImage: "arrow.uturn.backward") }
                .help(store.undoAvailability?.undo.map { "Undo " + $0.title } ?? "No Git operation to undo")
                .disabled(store.isBusy || store.undoAvailability?.undo == nil)
                Button {
                    if let record = store.undoAvailability?.redo { store.recoveryRequest = RecoveryRequest(action: .undo(record, true)) }
                } label: { Label("Redo Git Operation", systemImage: "arrow.uturn.forward") }
                .help(store.undoAvailability?.redo.map { "Redo " + $0.title } ?? "No Git operation to redo")
                .disabled(store.isBusy || store.undoAvailability?.redo == nil)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Group {
                Button { store.sync(.fetch) } label: { Label("Fetch", systemImage: "arrow.down.to.line") }.help("Fetch remotes")
                Button { store.sync(.pull) } label: { Label("Pull", systemImage: "arrow.down") }.help("Pull current branch (fast-forward only)").disabled(!store.canIntegrate)
                Button { store.sync(.push) } label: { Label("Push", systemImage: "arrow.up") }.help("Push current branch").disabled(!store.canIntegrate)
            }.disabled(!store.canUseRepository || snapshot.remotes.isEmpty)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                BranchNavigationMenu(store: store)
                Menu { IntegrationMenuItems(store: store) } label: { Label("Integrate", systemImage: "arrow.triangle.merge") }
                    .help("Merge, rebase and Git Flow")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.showingStashSheet = true } label: { Label("Save Stash", systemImage: "tray.and.arrow.down") }
                    .disabled(store.isBusy || store.changes.isEmpty || store.changes.contains(where: \.isConflicted)).help("Save local changes to a stash")
                Menu {
                    Section("Apply Stash") {
                        ForEach(snapshot.stashes.prefix(20)) { stash in Button(stash.subject) { store.applyStash(stash) } }
                    }
                    Button("Show All Stashes") { store.navigate(.stashes) }
                } label: { Label("Apply Stash", systemImage: "tray.and.arrow.up") }
                .disabled(store.isBusy || snapshot.stashes.isEmpty).help("Apply a saved stash")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button(action: store.refresh) { Label("Refresh", systemImage: "arrow.clockwise") }.help("Refresh (⌘R)").disabled(store.isBusy)
            }
            if let placeholder = store.destination.searchPlaceholder {
                ToolbarItem(placement: .primaryAction) {
                    ToolbarSearchField(text: $store.search, placeholder: placeholder, focusRequest: $store.searchFocusRequest).disabled(!store.canUseRepository).frame(minWidth: 150, idealWidth: 220, maxWidth: 240)
                }
            }
        }
    }
}

// SwiftUI owns the query; AppKit supplies native search sizing, focus and clear behavior.
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var focusRequest: UUID?
    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusRequest: $focusRequest) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.controlSize = .regular
        field.sendsSearchStringImmediately = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.focusRequest = $focusRequest
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.isEnabled = context.environment.isEnabled
        field.setAccessibilityLabel(placeholder)
        context.coordinator.focus(field, request: focusRequest)
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var lastFocusRequest: UUID?
        var focusRequest: Binding<UUID?>
        init(text: Binding<String>, focusRequest: Binding<UUID?> = .constant(nil)) { self.text = text; self.focusRequest = focusRequest }
        func focus(_ field: NSSearchField, request: UUID?) {
            guard request != lastFocusRequest else { return }
            lastFocusRequest = request
            guard let request else { return }
            Task { @MainActor [weak field, weak self] in
                guard let field, let self, field.isEnabled, self.lastFocusRequest == request, self.focusRequest.wrappedValue == request, let window = field.window else { return }
                window.makeFirstResponder(field); field.selectText(nil)
            }
        }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
    }
}
