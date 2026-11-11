import AppKit
import GitCore
import SwiftUI

struct SidebarReferenceContextActions: View {
    let store: RepositoryStore
    let ref: Reference
    var body: some View {
        Button("Preview History") { store.navigate(.reference(ref.fullName)) }
        if ref.isLocal {
            Button(ref.isCurrent ? "Current Branch" : "Check Out “\(ref.name)”") { store.switchBranch(ref) }
                .disabled(store.checkoutUnavailableReason(ref) != nil)
        }
        Divider()
        Button("Export Files at Revision…") { store.historical(.export, revision: ref.hash) }.disabled(store.isBusy)
        Button("Archive Files as ZIP…") { store.historical(.archive, revision: ref.hash) }.disabled(store.isBusy)
        Divider()
        if ref.isLocal {
            if let kind = store.flowConfiguration?.kind(of: ref.name), kind != .support { Button("Git Flow: \(kind.finishTitle)…") { store.manageFlow(.finish(ref.name)) }.disabled(store.isBusy || store.activeFlow != nil) }
            Button("Checkout Branch in New Worktree…") { store.manageWorktree(.create(ref.name)) }.disabled(store.worktrees.contains { $0.branch == ref.fullName })
            Button(store.organization.pinned.contains(ref.fullName) ? "Unpin Branch" : "Pin Branch") { store.organize(ref, pinned: !store.organization.pinned.contains(ref.fullName)) }
            Button("Track Upstream Branch…") { store.manage(.upstream(ref)) }
            Button("Publish / Push Branch…") { store.manage(.publish(ref, nil, nil, false)) }.disabled(store.managedRemotes.isEmpty)
            Button("Force Push with Lease…") { store.manage(.publish(ref, nil, nil, true)) }.disabled(store.managedRemotes.isEmpty)
            Button(store.organization.archived.contains(ref.fullName) ? "Unarchive Branch" : "Archive Branch") { store.organize(ref, archived: !store.organization.archived.contains(ref.fullName)) }
            Button("Rename Branch…") { store.manage(.renameBranch(ref)) }
            Button("Delete Branch…", role: .destructive) { store.manage(.deleteBranch(ref)) }.disabled(ref.isCurrent)
        }
        if ref.isRemote, let remote = store.remoteFor(ref) {
            Button("Check Out “\(ref.name)”") { store.switchRemoteBranch(ref) }.disabled(!store.canUseRepository || store.snapshot?.operation != RepositoryOperation.none)
            Button("Check Out as Tracking Branch…") { store.manage(.createBranch(ref.hash, ref.fullName)) }
            Button("Delete Remote Branch…", role: .destructive) { store.manage(.publish(nil, remote.name, "refs/heads/" + String(ref.name.dropFirst(remote.name.count + 1)), false)) }
        }
        if ref.isTag {
            Button("Tag Information…") { store.manage(.inspectTag(ref)) }
            Button("Rename Tag…") { store.manage(.renameTag(ref)) }
            Button("Delete Tag…", role: .destructive) { store.manage(.deleteTag(ref)) }
            Button("Publish Tag…") { store.manage(.publish(ref, nil, nil, false)) }.disabled(store.managedRemotes.isEmpty)
        }
        Divider()
        Button("Create New Branch from Here…") { store.manage(.createBranch(ref.hash, nil)) }
        Button("Create New Tag from Here…") { store.manage(.createTag(ref.hash)) }
        if !ref.isCurrent {
            Button("Merge into HEAD…") { store.integrationRequest = IntegrationRequest(action: .merge, revision: ref.fullName) }
            Button("Rebase HEAD onto This Branch…") { store.integrationRequest = IntegrationRequest(action: .rebase, revision: ref.fullName) }
        }
        Button("Compare with Revision…") { store.navigate(.comparison(ref.fullName)) }
        Button("Copy Name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ref.name, forType: .string) }
    }
}
