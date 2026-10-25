import AppKit
import GitCore
import SwiftUI

struct ContentView: View {
    @Bindable var store: RepositoryStore
    var body: some View {
        Group {
            if store.snapshot == nil { WelcomeView(store: store) }
            else {
                NavigationSplitView {
                    SidebarView(store: store)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 359, max: 450)
                } detail: {
                    switch store.destination {
                    case .worktrees: WorktreesView(store: store)
                    case .submodules: SubmodulesView(store: store)
                    case .workingCopy: WorkingCopyView(store: store)
                    case .history, .reference: HistoryView(store: store)
                    case .reflog: ReflogView(store: store)
                    case .stashes: StashesView(store: store)
                    case .branchesReview: BranchesReviewView(store: store)
                    case .repositorySettings: RepositorySettingsView(store: store)
                    case .fileHistory(let path, let revision):
                        if let repository = store.repository { FileHistoryView(store: store, repository: repository, path: path, revision: revision).id(store.repositoryToken.uuidString + path + revision) }
                    case .comparison(let left):
                        if let repository = store.repository { RevisionComparisonView(store: store, repository: repository, initialLeft: left).id(store.repositoryToken.uuidString + left) }
                    }
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .navigationTitle(store.title)
        .navigationSubtitle(store.navigationSubtitle)
        .toolbar { RepositoryToolbar(store: store) }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .safeAreaInset(edge: .top, spacing: 0) { VStack(spacing: 0) { AutomaticStashBanner(store: store); GitFlowOperationBanner(store: store); if store.destination != .workingCopy { OperationBanner(store: store) } } }
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
        .sheet(isPresented: $store.showingQuickActions) { QuickActionsSheet(store: store) }
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

    var statusBar: some View {
        HStack(spacing: 9) {
            if store.isBusy { ProgressView().controlSize(.mini); Text(store.activity) }
            else if let data = store.snapshot {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                Text("HEAD · " + data.branch)
                if data.ahead > 0 || data.behind > 0 { Text("↑\(data.ahead)  ↓\(data.behind)").foregroundStyle(.secondary) }
                Divider().frame(height: 12)
                Text("\(data.changes.count) changed files").foregroundStyle(.secondary)
            } else { Text("Ready to open a repository").foregroundStyle(.secondary) }
            Spacer()
            if let data = store.snapshot {
                Text(data.root.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11)).padding(.horizontal, 14).frame(height: 29)
        .background(.bar).overlay(alignment: .top) { Divider() }
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
            Text(title).font(.title2.bold())
            Text(caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $value).textFieldStyle(.roundedBorder).onSubmit(submit)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(button, action: submit).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 450)
    }
    func submit() { guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; action(value); dismiss() }
}
