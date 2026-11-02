import GitCore
import SwiftUI

struct RemoteEditSheet: View {
    enum Action: Sendable { case edit, rename, remove }
    let store: RepositoryStore
    let remote: RemoteConfiguration?
    let action: Action
    @State private var name = ""
    @State private var fetch = ""
    @State private var push = ""
    @Environment(\.dismiss) private var dismiss
    var title: LocalizedStringResource { action == .remove ? "Remove Remote" : action == .rename ? "Rename Remote" : remote == nil ? "Add Remote Repository" : "Edit Remote Repository" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetTitle(title)
            if action == .remove, let remote {
                LabeledContent("Name", value: remote.name)
                Text(remote.fetchURL).font(.callout).textSelection(.enabled)
                Text("Removes the local remote configuration and its tracking references. The server and its branches are unaffected. Configuration and reference recovery records are retained.").foregroundStyle(.secondary)
            } else {
                TextField("Name", text: $name).disabled(remote != nil && action == .edit)
                if action == .edit {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Fetch URLs").font(.callout)
                        TextEditor(text: $fetch).environment(\.layoutDirection, .leftToRight).font(.system(size: 12, design: .monospaced)).frame(height: 65).border(.quaternary)
                        Text("Push URLs (optional)").font(.callout)
                        TextEditor(text: $push).environment(\.layoutDirection, .leftToRight).font(.system(size: 12, design: .monospaced)).frame(height: 65).border(.quaternary)
                        Text("One URL per line. Without push URLs, Git uses the fetch URL. Existing fetch mappings and other remote settings are preserved.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ManagementFooter(title: action == .edit ? (remote == nil ? "Add Remote" : "Save Remote") : title, disabled: store.isBusy || (action != .remove && name.isEmpty) || (action == .edit && fetch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), destructive: action == .remove) {
                let name = name, fetch = fetch.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, push = push.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, remote = remote, action = action
                store.perform("\(title)…") { repository in
                    switch action {
                    case .edit:
                        if let remote { try await repository.editRemote(remote, fetchURLs: fetch, pushURLs: push) }
                        else { try await repository.addRemote(name: name, fetchURLs: fetch, pushURLs: push) }
                    case .rename: if let remote { try await repository.renameRemote(remote, to: name) }
                    case .remove: if let remote { try await repository.removeRemote(remote) }
                    }
                }; dismiss()
            }
        }.padding(24).frame(width: 560)
        .onAppear { name = remote?.name ?? ""; fetch = remote?.fetchURLs.joined(separator: "\n") ?? ""; push = remote?.pushURLs.joined(separator: "\n") ?? "" }
    }
}

struct RemoteFetchSheet: View {
    let store: RepositoryStore
    let initialRemote: RemoteConfiguration?
    @State private var name = ""
    @State private var prune = false
    @State private var tags = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetTitle("Fetch Remote Repository")
            Picker("Remote", selection: $name) { Text("All Remotes").tag(""); ForEach(store.managedRemotes) { Text($0.name).tag($0.name) } }
            Toggle("Prune Deleted Remote Branches", isOn: $prune)
            Toggle("Fetch All Tags", isOn: $tags)
            Text("Updates remote-tracking references without changing your working files. Pruning removes references to branches no longer on the server.").font(.callout).foregroundStyle(.secondary)
            ManagementFooter(title: "Fetch", disabled: store.isBusy || store.managedRemotes.isEmpty) {
                let remote = store.managedRemotes.first { $0.name == name }, prune = prune, tags = tags
                store.runRemoteFetch(remote, prune: prune, tags: tags); dismiss()
            }
        }.padding(24).frame(width: 520).onAppear { name = initialRemote?.name ?? "" }
    }
}


extension RepositoryStore {
    func runRemoteFetch(_ remote: RemoteConfiguration?, prune: Bool, tags: Bool) {
        perform("Fetching…", feedback: .fetch) { try await $0.fetchRemote(remote, prune: prune, tags: tags) }
    }

    func runRemotePush(_ preview: RemotePushPreview) {
        perform(preview.deletes ? "Deleting remote reference…" : "Pushing…", feedback: .push) { try await $0.executePush(preview) }
    }

    /// A normal push checks and writes in one operation; it never enables force or deletion.
    func runRemotePush(remote: RemoteConfiguration, source: Reference, destination: String, setUpstream: Bool, pushURL: String) {
        perform("Pushing…", feedback: .push) { repository in
            let checked = try await repository.pushPreview(remote: remote, source: source, destination: destination, setUpstream: setUpstream, pushURL: pushURL)
            try await repository.executePush(checked)
        }
    }
}
