import SwiftUI

struct IntegrationMenuItems: View {
    let store: RepositoryStore
    var body: some View {
        Section("Integrate into Current Branch") {
            Button("Merge…") { store.integrationRequest = IntegrationRequest(action: .merge) }
            Button("Rebase…") { store.integrationRequest = IntegrationRequest(action: .rebase) }
            Button("Interactive Rebase…") { store.rebaseRequest = RebaseRequest() }
        }.disabled(!store.canIntegrate)
        Section {
            Button("Compare Revisions…") { store.navigate(.comparison(store.destination.ref ?? "HEAD")) }.disabled(!store.canBrowseHistory)
            GitFlowToolbarMenu(store: store)
        }
    }
}
