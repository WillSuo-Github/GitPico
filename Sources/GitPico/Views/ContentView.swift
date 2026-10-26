import AppKit
import GitCore
import SwiftUI

struct ContentView: View {
    @Bindable var store: RepositoryStore
    var showsSidebar = true
    var body: some View {
        Group {
            if store.snapshot == nil || store.isChoosingRepository {
                if let workspace = store.workspace, let tab = workspace.tab(for: store) {
                    RepositoryPickerView(workspace: workspace, tab: tab, showsSidebar: showsSidebar)
                } else { WelcomeView(store: store) }
            } else if showsSidebar {
                NavigationSplitView {
                    SidebarView(store: store)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 359, max: 450)
                        .toolbar { ToolbarItem { RepositoryMenu(store: store) } }
                } detail: { RepositoryDetailView(store: store) }
            } else { RepositoryDetailView(store: store) }
        }
        .frame(minWidth: showsSidebar ? 1080 : 0, minHeight: showsSidebar ? 680 : 0)
        .navigationTitle(store.isChoosingRepository ? "Repositories" : store.title)
        .navigationSubtitle(store.isChoosingRepository ? "Choose a repository" : store.navigationSubtitle)
        .toolbar { if store.workspace == nil { RepositoryToolbar(store: store) } }
        .safeAreaInset(edge: .bottom, spacing: 0) { if showsSidebar { RepositoryStatusBar(store: store) } }
        .safeAreaInset(edge: .top, spacing: 0) { if !store.isChoosingRepository { VStack(spacing: 0) { AutomaticStashBanner(store: store); GitFlowOperationBanner(store: store); if store.destination != .workingCopy { OperationBanner(store: store) } } } }
        .task(id: store.search) { await store.searchHistory() }
        .alert("Git operation failed", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(item: $store.automaticStashRequest) { AutomaticStashSheet(store: store, request: $0) }
        .sheet(item: $store.integrationRequest, onDismiss: store.presentPendingAutomaticStash) { IntegrationSheet(store: store, request: $0) }
        .sheet(item: $store.lfsRequest) { LFSManagementSheet(store: store, request: $0) }
        .sheet(item: $store.flowRequest) { GitFlowManagementSheet(store: store, request: $0) }
        .sheet(item: $store.infrastructureRequest) { RepositoryInfrastructureSheet(store: store, request: $0) }
        .sheet(item: $store.relatedAdministrationRequest) { RelatedAdministrationSheet(store: store, request: $0) }
        .sheet(item: $store.worktreeRequest) { WorktreeManagementSheet(store: store, request: $0) }
        .sheet(item: $store.submoduleRequest) { SubmoduleManagementSheet(store: store, request: $0) }
        .sheet(item: $store.creationRequest) { RepositoryCreationSheet(store: store, request: $0) }
        .sheet(item: $store.rebaseRequest, onDismiss: store.presentPendingAutomaticStash) { InteractiveRebaseSheet(store: store, request: $0) }
        .sheet(item: $store.recoveryRequest) { HistoryRecoverySheet(store: store, request: $0) }
        .sheet(isPresented: $store.showingRebaseEdit) { RebaseEditSheet(store: store) }
        .sheet(item: $store.managementRequest, onDismiss: store.presentPendingAutomaticStash) { ManagementSheet(store: store, request: $0) }
        .sheet(item: $store.externalToolRequest) { ExternalToolSheet(store: store, request: $0) }
        .sheet(isPresented: $store.showingExternalToolSettings) { VStack { ExternalToolSettingsView(preferences: store.toolPreferences); Button("Close") { store.showingExternalToolSettings = false }.padding(.bottom) } }
        .sheet(isPresented: $store.showingRepositoryLibrary) { RepositoryLibraryView(store: store) }
        .sheet(isPresented: $store.showingQuickOpen) { QuickOpenSheet(store: store) }
        .sheet(item: $store.historicalRequest) { HistoricalFilesSheet(store: store, request: $0) }
        .sheet(item: $store.localChangeRequest) { LocalChangesSheet(store: store, request: $0) }
        .sheet(item: $store.stashRequest) { StashManagementSheet(store: store, request: $0) }
        .sheet(isPresented: $store.showingBranchSheet, onDismiss: store.presentPendingAutomaticStash) {
            BranchCreateSheet(store: store, revision: "HEAD", upstream: nil)
        }
        .sheet(isPresented: $store.showingStashSheet) {
            StashSaveSheet(store: store, paths: [], snapshot: false)
        }
    }


}

struct InputSheet: View {
    let title: String
    let caption: String
    let placeholder: String
    let button: String
    let action: (String) -> Void
    @State private var value = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title)
            Text(caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $value).textFieldStyle(.roundedBorder).onSubmit(submit)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(button, action: submit).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 450)
    }
    func submit() { guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; action(value); dismiss() }
}
