import GitCore
import SwiftUI

struct ManagementSheet: View {
    let store: RepositoryStore
    let request: ManagementRequest
    var body: some View {
        switch request.action {
        case .createBranch(let revision, let upstream): BranchCreateSheet(store: store, revision: revision, upstream: upstream)
        case .createTag(let revision): TagCreateSheet(store: store, revision: revision)
        case .renameBranch(let ref): ReferenceEditSheet(store: store, reference: ref, action: .rename)
        case .deleteBranch(let ref): ReferenceEditSheet(store: store, reference: ref, action: .delete)
        case .upstream(let ref): ReferenceEditSheet(store: store, reference: ref, action: .upstream)
        case .renameTag(let ref): ReferenceEditSheet(store: store, reference: ref, action: .rename)
        case .deleteTag(let ref): ReferenceEditSheet(store: store, reference: ref, action: .delete)
        case .inspectTag(let ref): TagInformationSheet(store: store, reference: ref)
        case .addRemote: RemoteEditSheet(store: store, remote: nil, action: .edit)
        case .editRemote(let remote): RemoteEditSheet(store: store, remote: remote, action: .edit)
        case .renameRemote(let remote): RemoteEditSheet(store: store, remote: remote, action: .rename)
        case .removeRemote(let remote): RemoteEditSheet(store: store, remote: remote, action: .remove)
        case .publish(let ref, let remote, let destination, let force): RemotePushSheet(store: store, source: ref, remoteName: remote, destination: destination, force: force)
        case .fetch(let remote): RemoteFetchSheet(store: store, initialRemote: remote)
        case .recovery: ManagementRecoverySheet(store: store)
        }
    }
}

struct RevisionField: View {
    let store: RepositoryStore
    @Binding var value: String
    var body: some View {
        HStack {
            TextField("Revision", text: $value).labelsHidden().accessibilityLabel("Revision")
            Menu {
                Button("HEAD") { value = "HEAD" }
                ForEach(store.snapshot?.references ?? []) { ref in Button(ref.name) { value = ref.fullName } }
            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }.accessibilityElement(children: .contain)
    }
}

struct ManagementFooter: View {
    let title: String
    var disabled = false
    var destructive = false
    let submit: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(title, role: destructive ? .destructive : nil, action: submit).keyboardShortcut(.defaultAction).disabled(disabled)
        }
    }
}
