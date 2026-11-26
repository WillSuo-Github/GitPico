import AppKit
import GitCore
import SwiftUI

/// Repository navigation and Undo/Redo lead; an open center separates remote sync,
/// stash, external tools and search on the trailing side. Refresh lives in the status bar (⌘R).
struct RepositoryToolbar: CustomizableToolbarContent {
    static let customizationIdentifier = "GitPico.repositoryToolbar"

    @Bindable var store: RepositoryStore
    var showsWorkspaceNavigation = true
    var body: some CustomizableToolbarContent {
        if showsWorkspaceNavigation {
            ToolbarItem(id: "repository.back", placement: .navigation) {
                Button(action: store.goBack) { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!store.canGoBack)
                    .help(Text(verbatim: String(localized: "Back") + " (⌘[)"))
            }
            ToolbarItem(id: "repository.forward", placement: .navigation) {
                Button(action: store.goForward) { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!store.canGoForward)
                    .help(Text(verbatim: String(localized: "Forward") + " (⌘])"))
            }
        }
        ToolbarItem(id: "repository.undo", placement: .navigation) {
            Button {
                if let record = store.undoAvailability?.undo { store.recoveryRequest = RecoveryRequest(action: .undo(record, false)) }
            } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            .help(store.undoAvailability?.undo.map { String(localized: "Undo \($0.title) (⌥⌘Z)") } ?? String(localized: "No Git operation to undo"))
            .disabled(store.isBusy || store.undoAvailability?.undo == nil)
        }
        ToolbarItem(id: "repository.redo", placement: .navigation) {
            Button {
                if let record = store.undoAvailability?.redo { store.recoveryRequest = RecoveryRequest(action: .undo(record, true)) }
            } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            .help(store.undoAvailability?.redo.map { String(localized: "Redo \($0.title) (⇧⌥⌘Z)") } ?? String(localized: "No Git operation to redo"))
            .disabled(store.isBusy || store.undoAvailability?.redo == nil)
        }
        // An empty principal view preserves AppKit's trailing action layout.
        // ToolbarSpacer alone is folded away when there is no principal item.
        ToolbarItem(id: "repository.centerSpacing", placement: .principal) {
            RepositoryToolbarActivityView(store: store)
        }
        .sharedBackgroundVisibility(.hidden)
        .customizationBehavior(.disabled)
        ToolbarItem(id: "repository.fetch", placement: .primaryAction) {
            RepositorySyncButton(store: store, action: .fetch)
        }
        ToolbarItem(id: "repository.pull", placement: .primaryAction) {
            RepositorySyncButton(store: store, action: .pull)
        }
        ToolbarItem(id: "repository.push", placement: .primaryAction) {
            RepositorySyncButton(store: store, action: .push)
        }
        ToolbarItem(id: "repository.stash", placement: .primaryAction) {
            StashToolbarMenu(store: store, stashes: store.snapshot?.stashes ?? [])
        }
        ToolbarItem(id: "repository.terminal", placement: .primaryAction) {
            TerminalToolbarButton(store: store)
        }
        ToolbarItem(id: "repository.openExternal", placement: .primaryAction) {
            OpenExternalToolbarMenu(store: store)
        }
        ToolbarItem(id: "repository.refresh", placement: .primaryAction) {
            Button(action: store.refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!store.canUseRepository)
            .help(Text(verbatim: String(localized: "Refresh") + " (⌘R)"))
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "repository.finder", placement: .primaryAction) {
            Button(action: store.revealRepositoryInFinder) {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(!store.canInspectRepository)
            .help("Reveal in Finder")
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "repository.newBranch", placement: .primaryAction) {
            Button {
                store.showingBranchSheet = true
            } label: {
                Label("New Branch", systemImage: "arrow.triangle.branch")
            }
            .disabled(!store.canIntegrate)
            .help(Text(verbatim: String(localized: "New Branch…") + " (⇧⌘B)"))
        }
        .defaultCustomization(.hidden)
        ToolbarItem(id: "repository.search", placement: .primaryAction) {
            RepositorySearchView(store: store)
                .frame(width: 240)
                .accessibilityLabel("Search")
        }
    }
}

struct RepositoryPickerToolbar: CustomizableToolbarContent {
    static let toolbarIdentifier = "GitPico.pickerToolbar"

    @Bindable var store: RepositoryStore
    var body: some CustomizableToolbarContent {
        if store.workspace != nil {
            ToolbarItem(id: "picker.back", placement: .navigation) {
                Button(action: store.goBack) { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!store.canGoBack)
                    .help(Text(verbatim: String(localized: "Back") + " (⌘[)"))
            }
            .customizationBehavior(.disabled)
            ToolbarItem(id: "picker.forward", placement: .navigation) {
                Button(action: store.goForward) { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!store.canGoForward)
                    .help(Text(verbatim: String(localized: "Forward") + " (⌘])"))
            }
            .customizationBehavior(.disabled)
        }
    }
}

struct TerminalToolbarButton: View {
    let store: RepositoryStore
    @State private var catalog = ExternalAppCatalog.shared

    private var resolvedTerminal: ResolvedExternalApp {
        catalog.resolve(kind: .terminal, settings: store.toolPreferences.value)
    }

    private var helpText: String {
        switch resolvedTerminal {
        case .configured(let app), .automatic(let app):
            return String(localized: "Open in \(app.name) (⌃⌘T)")
        case .missingConfigured:
            return String(localized: "Configured terminal not found. Update Default Terminal in Settings → External Tools.")
        case .unavailable:
            return String(localized: "Open in Terminal (⌃⌘T)")
        }
    }

    var body: some View {
        Button {
            store.openInTerminal(catalog: catalog)
        } label: {
            Label("Terminal", systemImage: "terminal")
        }
        .disabled(!store.canInspectRepository)
        .help(helpText)
    }
}

struct OpenExternalToolbarMenu: View {
    let store: RepositoryStore
    @State private var catalog = ExternalAppCatalog.shared
    @Environment(\.openSettings) private var openSettings

    private var resolvedEditor: ResolvedExternalApp {
        catalog.resolve(kind: .editor, settings: store.toolPreferences.value)
    }

    private var primaryEditor: InstalledExternalApp? {
        resolvedEditor.app
    }

    private var otherEditors: [InstalledExternalApp] {
        guard let primaryEditor else { return catalog.installedEditors }
        return catalog.installedEditors.filter { $0.url != primaryEditor.url }
    }

    private var helpText: String {
        switch resolvedEditor {
        case .configured(let app), .automatic(let app):
            return String(localized: "Open in \(app.name) (⌃⌘E). Open the menu for other editors, Finder, and remote links.")
        case .missingConfigured:
            return String(localized: "Configured editor not found. Open the menu for Finder, remote links, or settings.")
        case .unavailable:
            return String(localized: "Reveal in Finder. Open the menu for remote links or choose a default editor.")
        }
    }

    var body: some View {
        let links = store.hostedRemoteLinks
        Menu {
            if let editor = primaryEditor {
                Section("Editor") {
                    Button {
                        store.openInEditor(editor, catalog: catalog)
                    } label: {
                        Label {
                            Text("Open in \(editor.name)")
                        } icon: {
                            Image(nsImage: editor.menuIcon)
                        }
                    }
                    ForEach(otherEditors) { app in
                        Button {
                            store.openInEditor(app, catalog: catalog)
                        } label: {
                            Label {
                                Text("Open in \(app.name)")
                            } icon: {
                                Image(nsImage: app.menuIcon)
                            }
                        }
                    }
                }
                Divider()
            }
            Button {
                store.revealRepositoryInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Button {
                store.copyRepositoryPath()
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            if !links.isEmpty {
                Divider()
                if links.count == 1, let link = links.first {
                    Link(destination: link.repository.webURL) {
                        Label(
                            link.repository.provider == .github ? "Open on GitHub" : "Open on GitLab",
                            systemImage: "globe"
                        )
                    }
                    HostedReviewWebMenu(store: store)
                } else {
                    Menu {
                        ForEach(links) { link in
                            Link("\(link.name) · \(link.repository.project)", destination: link.repository.webURL)
                        }
                    } label: {
                        Label("Open Repository on Web", systemImage: "globe")
                    }
                    HostedReviewWebMenu(store: store)
                }
            }
            Divider()
            Button {
                AppSettingsNavigation.shared.selection = .externalTools
                openSettings()
            } label: {
                Label("External Tool Settings…", systemImage: "gearshape")
            }
        } label: {
            Label("Open In", systemImage: "arrow.up.forward.app")
        } primaryAction: {
            switch resolvedEditor {
            case .configured, .automatic, .missingConfigured:
                store.openInEditor(catalog: catalog)
            case .unavailable:
                store.revealRepositoryInFinder()
            }
        }
        .disabled(!store.canInspectRepository)
        .help(helpText)
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
                }.disabled(store.isBusy)
            }
            Divider()
            Button("Show All Stashes") { store.navigate(.stashes) }
        } label: {
            Label("Stash", systemImage: "tray.and.arrow.down")
        } primaryAction: {
            if canSave { store.showingStashSheet = true } else { store.navigate(.stashes) }
        }
        .disabled(!store.canInspectRepository)
        .help(canSave ? "Stash local changes (⌘⇧S). Open the menu to apply a saved stash." : "Show stashes. Open the menu to apply a saved stash.")
    }
}
