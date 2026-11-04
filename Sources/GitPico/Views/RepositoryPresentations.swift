import SwiftUI

/// Present requests from the frontmost repository surface, including nested settings operations.
struct RepositoryPresentations: ViewModifier {
    @Bindable var store: RepositoryStore
    var settingsContext = false
    private var active: Bool { settingsContext || !store.showingRepositorySettings }
    private func item<T>(_ value: Binding<T?>) -> Binding<T?> {
        Binding(get: { active ? value.wrappedValue : nil }, set: { value.wrappedValue = $0 })
    }
    private func flag(_ value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { active && value.wrappedValue }, set: { value.wrappedValue = $0 })
    }
    func body(content: Content) -> some View {
        content
        .alert("Git operation failed", isPresented: Binding(get: { active && store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(item: item($store.automaticStashRequest)) { AutomaticStashSheet(store: store, request: $0) }
        .sheet(item: item($store.integrationRequest), onDismiss: store.presentPendingAutomaticStash) { IntegrationSheet(store: store, request: $0) }
        .sheet(item: item($store.batchIntegrationRequest)) { BatchIntegrationSheet(store: store, request: $0) }
        .sheet(item: item($store.pullRequest), onDismiss: store.finishPullReview) { PullReviewSheet(store: store, request: $0) }
        .sheet(item: item($store.lfsRequest)) { LFSManagementSheet(store: store, request: $0) }
        .sheet(item: item($store.flowRequest)) { GitFlowManagementSheet(store: store, request: $0) }
        .sheet(item: item($store.infrastructureRequest)) { RepositoryInfrastructureSheet(store: store, request: $0) }
        .sheet(item: item($store.relatedAdministrationRequest)) { RelatedAdministrationSheet(store: store, request: $0) }
        .sheet(item: item($store.worktreeRequest)) { WorktreeManagementSheet(store: store, request: $0) }
        .sheet(item: item($store.submoduleRequest)) { SubmoduleManagementSheet(store: store, request: $0) }
        .sheet(item: item($store.creationRequest)) { RepositoryCreationSheet(store: store, request: $0) }
        .sheet(item: item($store.rebaseRequest), onDismiss: store.presentPendingAutomaticStash) { InteractiveRebaseSheet(store: store, request: $0) }
        .sheet(item: item($store.recoveryRequest)) { HistoryRecoverySheet(store: store, request: $0) }
        .sheet(isPresented: flag($store.showingRebaseEdit)) { RebaseEditSheet(store: store) }
        .sheet(isPresented: flag($store.showingLFSLocks)) { LFSLocksView(store: store) }
        .sheet(item: item($store.managementRequest), onDismiss: store.presentPendingAutomaticStash) { ManagementSheet(store: store, request: $0) }
        .sheet(item: item($store.externalToolRequest)) { ExternalToolSheet(store: store, request: $0) }
        .sheet(isPresented: flag($store.showingExternalToolSettings)) { VStack { ExternalToolSettingsView(preferences: store.toolPreferences); Button("Close") { store.showingExternalToolSettings = false }.padding(.bottom) } }
        .sheet(isPresented: flag($store.showingRepositoryLibrary)) { RepositoryLibraryView(store: store) }
        .sheet(isPresented: flag($store.showingQuickOpen)) { QuickOpenSheet(store: store) }
        .sheet(isPresented: flag($store.showingConflictDrafts)) { ConflictDraftsSheet(store: store) }
        .sheet(isPresented: flag($store.showingNetworkActivity), onDismiss: {
            if store.authenticationAfterNetwork { store.authenticationAfterNetwork = false; store.showingAuthentication = true }
            else if let mode = store.fetchAfterNetwork {
                store.fetchAfterNetwork = nil
                store.reviewFetch(mode: mode)
            }
        }) { NetworkActivityView(store: store) }
        .sheet(isPresented: flag($store.showingAuthentication), onDismiss: {
            if store.networkAfterAuthentication { store.networkAfterAuthentication = false; store.showingNetworkActivity = true }
        }) {
            AuthenticationPanel(store: store)
        }
        .sheet(item: item($store.historicalRequest)) { HistoricalFilesSheet(store: store, request: $0) }
        .sheet(item: item($store.localChangeRequest)) { LocalChangesSheet(store: store, request: $0) }
        .sheet(item: item($store.stashRequest)) { StashManagementSheet(store: store, request: $0) }
        .sheet(isPresented: flag($store.showingBranchSheet), onDismiss: store.presentPendingAutomaticStash) {
            BranchCreateSheet(store: store, revision: "HEAD", upstream: nil)
        }
        .sheet(isPresented: flag($store.showingStashSheet)) {
            StashSaveSheet(store: store, paths: [], snapshot: false)
        }
        .sheet(isPresented: Binding(get: { !settingsContext && store.showingRepositorySettings }, set: { if !settingsContext { store.showingRepositorySettings = $0 } }), onDismiss: {
            store.finishRepositorySettings()
        }) {
            AnyView(RepositorySettingsView(store: store).modifier(RepositoryPresentations(store: store, settingsContext: true)))
        }
    }
}
