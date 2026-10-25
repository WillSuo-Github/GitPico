import GitCore
import SwiftUI

struct BranchNavigationMenu: View {
    let store: RepositoryStore
    var body: some View {
        Menu {
            Text("Current Branch: " + (store.snapshot?.branch ?? "None"))
            if let ref = store.previewedReference, ref.isLocal {
                Button("Check Out “\(ref.name)”") { store.switchBranch(ref) }
                    .disabled(store.checkoutUnavailableReason(ref) != nil)
            }
            Divider()
            Button("New Branch…") { store.showingBranchSheet = true }.disabled(!store.canIntegrate)
            Menu("Preview Branch History") {
                ForEach((store.snapshot?.references ?? []).filter(\.isLocal).prefix(200)) { ref in
                    Button { store.navigate(.reference(ref.fullName)) } label: {
                        if ref.isCurrent { Label(ref.name, systemImage: "checkmark") } else { Text(ref.name) }
                    }
                }
                Divider()
                Button("Show All Branches") { store.navigate(.branchesReview) }
            }
        } label: { Label("Branches", systemImage: "arrow.triangle.branch") }
        .help("Current branch: " + (store.snapshot?.branch ?? "None") + ". Preview or check out branches.")
        .disabled(!store.canUseRepository)
    }
}
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
