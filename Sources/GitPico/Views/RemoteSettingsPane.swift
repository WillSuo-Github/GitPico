import GitCore
import SwiftUI

struct RemoteSettingsPane: View {
    let store: RepositoryStore
    var body: some View {
        Form {
            ForEach(store.managedRemotes) { remote in
                Section(remote.name) {
                    LabeledContent("Fetch URLs") { Text(remote.fetchURLs.joined(separator: "\n")).textSelection(.enabled) }
                    LabeledContent("Push URLs") { Text(remote.pushURLs.isEmpty ? "Use fetch URL" : remote.pushURLs.joined(separator: "\n")).textSelection(.enabled) }
                    if !remote.refspecs.isEmpty { LabeledContent("Fetch mappings") { Text(remote.refspecs.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) } }
                    HStack {
                        Button("Fetch…") { store.manage(.fetch(remote)) }
                        Button("Edit…") { store.manage(.editRemote(remote)) }
                        Button("Rename…") { store.manage(.renameRemote(remote)) }
                        Spacer()
                        Button("Remove…", role: .destructive) { store.manage(.removeRemote(remote)) }
                    }.controlSize(.small)
                }
            }
            if store.managedRemotes.isEmpty { Text("No remotes configured.").foregroundStyle(.secondary) }
            HStack {
                Button("Add Remote…") { store.manage(.addRemote) }
                Spacer()
                Button("Recover Removed Remotes…") { store.manage(.recovery) }
            }
        }.formStyle(.grouped).disabled(store.isBusy)
    }
}
