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
                store.perform("Fetching…") { try await $0.fetchRemote(remote, prune: prune, tags: tags) }; dismiss()
            }
        }.padding(24).frame(width: 520).onAppear { name = initialRemote?.name ?? "" }
    }
}

struct RemotePushSheet: View {
    let store: RepositoryStore
    let source: Reference?
    let remoteName: String?
    let destination: String?
    let force: Bool
    @State private var sourceID = ""
    @State private var remoteID = ""
    @State private var destinationName = ""
    @State private var urls: [String] = []
    @State private var pushURL = ""
    @State private var tracking = false
    @State private var lease = false
    @State private var preview: RemotePushPreview?
    @State private var loading = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    var deleting: Bool { source == nil && destination != nil }
    var selectedSource: Reference? { source ?? store.snapshot?.references.first { $0.id == sourceID } }
    var selectedRemote: RemoteConfiguration? { store.managedRemotes.first { $0.name == remoteID } }
    var refs: [Reference] { (store.snapshot?.references ?? []).filter { $0.isLocal || $0.isTag } }
    var revision: String { deleting ? destinationName : (selectedSource?.isTag == true ? "refs/tags/" : "refs/heads/") + destinationName }
    var title: LocalizedStringResource { deleting ? "Delete Remote Reference" : lease ? "Force Push with Lease" : "Publish / Push" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetTitle(title)
            if let preview {
                Grid(alignment: .leading, verticalSpacing: 10) {
                    GridRow { Text("Remote").foregroundStyle(.secondary); Text(preview.remote.name) }
                    GridRow { Text("Push URL").foregroundStyle(.secondary); Text(preview.pushURL).textSelection(.enabled).lineLimit(3) }
                    GridRow { Text("Destination").foregroundStyle(.secondary); Text(preview.destination).textSelection(.enabled) }
                    GridRow { Text("Server object").foregroundStyle(.secondary); Text(preview.remoteHash.map { String($0.prefix(12)) } ?? String(localized: "Does not exist yet")) }
                    GridRow { Text("New object").foregroundStyle(.secondary); Text(preview.source.map { String($0.hash.prefix(12)) } ?? String(localized: "Delete")) }
                }.font(.system(size: 12))
                if preview.forceWithLease || preview.deletes { Label("Rejected if the server reference changes after this preview.", systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary) }
                if preview.setUpstream { Text("Sets this local branch's upstream after the push succeeds.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Back") { self.preview = nil }
                    ManagementFooter(title: deleting ? "Delete on Remote" : "Push", disabled: store.isBusy, destructive: deleting || lease) {
                        store.perform(deleting ? "Deleting remote reference…" : "Pushing…") { try await $0.executePush(preview) }; dismiss()
                    }
                }
            } else {
                Form {
                    Picker("Remote", selection: $remoteID) { ForEach(store.managedRemotes) { Text($0.name).tag($0.name) } }
                    if !deleting {
                        Picker("Local reference", selection: $sourceID) { ForEach(refs) { Text($0.isTag ? String(localized: "Tag · \($0.name)") : String(localized: "Branch · \($0.name)")).tag($0.id) } }.disabled(source != nil)
                        TextField(selectedSource?.isTag == true ? "Remote tag" : "Remote branch", text: $destinationName)
                    } else { TextField("Remote Reference (refs/heads/… or refs/tags/…)", text: $destinationName) }
                    Picker("Push URL", selection: $pushURL) { ForEach(urls, id: \.self) { Text($0).tag($0) } }
                    if !deleting {
                        Toggle("Force Push with Lease", isOn: $lease)
                        Toggle("Set Upstream Tracking", isOn: $tracking).disabled(selectedSource?.isLocal != true)
                    }
                }
                Text(deleting ? "Deletes only this reference on the selected server. Existing local commits and references are retained." : "Review the exact destination and server object before pushing. With multiple push URLs, this action writes only to the selected URL.").font(.callout).foregroundStyle(.secondary)
                if let failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    if loading { ProgressView().controlSize(.small) }
                    ManagementFooter(title: "Review…", disabled: store.isBusy || loading || selectedRemote == nil || pushURL.isEmpty || (!deleting && (selectedSource == nil || destinationName.isEmpty))) { Task { await review() } }
                }
            }
        }.padding(24).frame(width: 620)
        .onAppear {
            remoteID = remoteName ?? store.managedRemotes.first?.name ?? ""
            sourceID = source?.id ?? refs.first(where: \.isCurrent)?.id ?? refs.first?.id ?? ""
            destinationName = deleting ? destination ?? "" : selectedSource?.name ?? ""
            lease = force
            tracking = selectedSource?.isLocal == true && selectedSource?.upstream.isEmpty == true
        }
        .task(id: remoteID) {
            urls = []; pushURL = ""; failure = nil
            guard let remote = selectedRemote, let repo = store.repository else { return }
            do { let value = try await repo.effectivePushURLs(remote); guard !Task.isCancelled else { return }; urls = value; pushURL = value.first ?? "" } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        .onChange(of: sourceID) { if !deleting { destinationName = selectedSource?.name ?? "" }; if selectedSource?.isTag == true { tracking = false } }
    }
    private func review() async {
        guard let remote = selectedRemote, let repo = store.repository else { return }
        loading = true; failure = nil
        defer { loading = false }
        do { preview = try await repo.pushPreview(remote: remote, source: deleting ? nil : selectedSource, destination: revision, forceWithLease: lease, setUpstream: tracking, pushURL: pushURL) }
        catch { failure = error.localizedDescription }
    }
}
