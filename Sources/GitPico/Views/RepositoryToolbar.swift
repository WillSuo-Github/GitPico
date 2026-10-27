import AppKit
import GitCore
import SwiftUI

/// Repository navigation and Undo/Redo lead; an open center separates remote sync,
/// stash and search on the trailing side. Refresh lives in the status bar (⌘R).
struct RepositoryToolbar: ToolbarContent {
    @Bindable var store: RepositoryStore
    var body: some ToolbarContent {
        if store.snapshot == nil && store.workspace == nil {
            ToolbarItem(placement: .navigation) { RepositoryMenu(store: store) }
        }
        if store.workspace != nil {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: store.goBack) { Label("Previous Repository", systemImage: "chevron.left") }.disabled(!store.canGoBack).help("Back to previous repository (⌘[)")
                Button(action: store.goForward) { Label("Next Repository", systemImage: "chevron.right") }.disabled(!store.canGoForward).help("Forward to next repository (⌘])")
            }
        }
        if let snapshot = store.snapshot, !store.isChoosingRepository {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    if let record = store.undoAvailability?.undo { store.recoveryRequest = RecoveryRequest(action: .undo(record, false)) }
                } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .help(store.undoAvailability?.undo.map { "Undo " + $0.title + " (⌥⌘Z)" } ?? "No Git operation to undo")
                .disabled(store.isBusy || store.undoAvailability?.undo == nil)
                Button {
                    if let record = store.undoAvailability?.redo { store.recoveryRequest = RecoveryRequest(action: .undo(record, true)) }
                } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .help(store.undoAvailability?.redo.map { "Redo " + $0.title + " (⇧⌥⌘Z)" } ?? "No Git operation to redo")
                .disabled(store.isBusy || store.undoAvailability?.redo == nil)
            }
            // An empty principal view preserves AppKit's trailing action layout.
            // ToolbarSpacer alone is folded away when there is no principal item.
            ToolbarItem(id: "repository.centerSpacing", placement: .principal) {
                Color.clear.frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
            }.sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .primaryAction) {
                Group {
                    Button { store.sync(.fetch) } label: { Label("Fetch", systemImage: "arrow.down.circle") }.help("Fetch all remotes")
                    Button { store.sync(.pull) } label: { Label("Pull", systemImage: "arrow.down") }
                        .help("Review Pull strategy (" + AppPreferences.shared.pullPolicy.title + ")").disabled(!store.canIntegrate)
                    Button { store.sync(.push) } label: { Label("Push", systemImage: "arrow.up") }
                        .help(snapshot.ahead > 0 ? "Push \(snapshot.ahead) outgoing commits" : "Push current branch").disabled(!store.canIntegrate)
                }.disabled(!store.canUseRepository || snapshot.remotes.isEmpty)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { StashToolbarMenu(store: store, stashes: snapshot.stashes) }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(id: "repository.search", placement: .primaryAction) {
                RepositorySearchView(store: store).frame(width: 240)
            }
        }
    }
}

/// One control for both directions of the stash: click saves, the menu applies.
struct StashToolbarMenu: View {
    let store: RepositoryStore
    let stashes: [Stash]
    var canSave: Bool { !store.isBusy && !store.changes.isEmpty && !store.changes.contains(where: \.isConflicted) }
    var body: some View {
        Menu {
            Button("Save Stash…") { store.showingStashSheet = true }.disabled(!canSave)
            if !stashes.isEmpty {
                Section("Apply Stash") {
                    ForEach(stashes.prefix(20)) { stash in Button(stash.subject) { store.applyStash(stash) } }
                }
            }
            Divider()
            Button("Show All Stashes") { store.navigate(.stashes) }
        } label: {
            Label("Stash", systemImage: "tray.and.arrow.down")
        } primaryAction: {
            if canSave { store.showingStashSheet = true } else { store.navigate(.stashes) }
        }
        .disabled(!store.canUseRepository)
        .help(canSave ? "Stash local changes (⌘⇧S). Open the menu to apply a saved stash." : "Show stashes. Open the menu to apply a saved stash.")
    }
}
