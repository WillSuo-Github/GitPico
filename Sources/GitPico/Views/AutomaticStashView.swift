import GitCore
import SwiftUI

struct AutomaticStashSheet: View {
    let store: RepositoryStore
    let request: AutomaticStashRequest
    @State private var restoreAfter = false
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Stash Current Local Changes").font(.title2.bold())
            Text("Your working copy contains uncommitted changes. Save them on the stash before continuing?").foregroundStyle(.secondary)
            LabeledContent("Operation", value: request.title)
            TextField("Optional Stash Message", text: $message)
            Toggle("Re-Apply Changes After Operation is Finished", isOn: $restoreAfter)
            Text("Includes untracked files. Reapplying restores the staging area too. Saved work remains recoverable if the operation or restoration needs attention.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Abort") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Do Not Stash") { store.perform(request.title, refresh: request.refresh, action: request.action); dismiss() }
                Button("Stash Changes") {
                    store.runAutomaticStash(request, message: message, restoreAfter: restoreAfter)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(store.changes.contains(where: \.isConflicted))
            }
        }.padding(24).frame(width: 570)
    }
}

struct AutomaticStashBanner: View {
    let store: RepositoryStore
    var body: some View {
        if let record = store.automaticStash {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label(record.phase == .waiting ? "Automatic stash waiting" : "Review automatic stash", systemImage: "tray.full.fill").fontWeight(.medium)
                    Spacer()
                    Button("Show Stashes") { store.navigate(.stashes) }
                    if record.phase == .waiting {
                        Button("Restore Changes") { store.restoreAutomaticStash() }.disabled(!store.changes.isEmpty || store.snapshot?.operation != RepositoryOperation.none)
                    } else if record.phase == .applying || record.phase == .needsReview {
                        Button("Finish Recovery") { store.completeAutomaticStash(keepSaved: false) }.disabled(store.changes.contains(where: \.isConflicted) || store.snapshot?.operation != RepositoryOperation.none)
                    }
                    Button("Keep Saved Stash") { store.completeAutomaticStash(keepSaved: true) }.disabled(store.snapshot?.operation != RepositoryOperation.none || store.changes.contains(where: \.isConflicted))
                }
                Text(record.phase == .waiting ? "Saved before \(record.title). Finish or abort the Git operation to restore the saved changes and index." : "Restoration was attempted or interrupted. Inspect the working copy, resolve conflicts and finish recovery; saved content is retained. No changes will be replayed automatically.")
                    .foregroundStyle(.secondary)
            }.font(.system(size: 11)).controlSize(.small).padding(10).background(.orange.opacity(0.08)).disabled(store.isBusy)
        }
    }
}
