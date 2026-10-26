import GitCore
import SwiftUI

/// The branch control is the hub for everything that changes HEAD: switch, create, preview and integrate.
struct BranchNavigationMenu: View {
    let store: RepositoryStore
    var branch: String { store.snapshot?.branch ?? "None" }
    var locals: [Reference] { (store.snapshot?.references ?? []).filter(\.isLocal) }
    var body: some View {
        // Wrapped so the toolbar hosts a view (branch name visible) instead of an icon-only menu item.
        HStack(spacing: 0) { menu }.fixedSize().accessibilityElement(children: .contain).accessibilityLabel("Branch " + branch)
    }
    var menu: some View {
        Menu {
            Section("On " + branch + syncText) {
                if let ref = store.previewedReference, ref.isLocal, !ref.isCurrent {
                    Button("Check Out “\(ref.name)”") { store.switchBranch(ref) }
                        .disabled(store.checkoutUnavailableReason(ref) != nil)
                }
                Button("New Branch…") { store.showingBranchSheet = true }.disabled(!store.canIntegrate)
                Menu("Switch to Branch") {
                    ForEach(locals.prefix(200)) { ref in
                        Button { store.switchBranch(ref) } label: {
                            if ref.isCurrent { Label(ref.name, systemImage: "checkmark") } else { Text(ref.name) }
                        }.disabled(ref.isCurrent || store.checkoutUnavailableReason(ref) != nil)
                    }
                }
                Menu("Preview Branch History") {
                    ForEach(locals.prefix(200)) { ref in
                        Button { store.navigate(.reference(ref.fullName)) } label: {
                            if ref.isCurrent { Label(ref.name, systemImage: "checkmark") } else { Text(ref.name) }
                        }
                    }
                }
            }
            IntegrationMenuItems(store: store)
            Divider()
            Button("Review All Branches") { store.navigate(.branchesReview) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                Text(branch).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
                if let snapshot = store.snapshot, snapshot.ahead > 0 || snapshot.behind > 0 {
                    Text(syncText.trimmingCharacters(in: .whitespaces)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 6)
        }
        .menuStyle(.borderlessButton)
        .help("Current branch: " + branch + syncText + ". Switch, create, merge or rebase branches.")
        .disabled(!store.canUseRepository && !store.isBackgroundFetching)
    }
    var syncText: String {
        guard let snapshot = store.snapshot, snapshot.ahead > 0 || snapshot.behind > 0 else { return "" }
        return "  ↑\(snapshot.ahead) ↓\(snapshot.behind)"
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
