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
    @State private var name: String
    @State private var branch = ""
    @State private var options: FetchOptions
    @State private var showAdvanced: Bool
    @Environment(\.dismiss) private var dismiss

    init(store: RepositoryStore, initialRemote: RemoteConfiguration?, mode: FetchReviewMode) {
        self.store = store
        let singleRemote = store.managedRemotes.count == 1 ? store.managedRemotes.first : nil
        _name = State(initialValue: initialRemote?.name ?? singleRemote?.name ?? "")
        _showAdvanced = State(initialValue: mode != .standard)
        var options = FetchOptions()
        if mode == .largeTransfer { options.tags = .skip; options.timeLimit = .extended }
        _options = State(initialValue: options)
    }

    private var selectedRemote: RemoteConfiguration? { store.managedRemotes.first { $0.name == name } }
    private var branchName: String? {
        let value = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || value.isEmpty ? nil : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle("Fetch Remote Repository", icon: "arrow.down.circle")
            Picker("Remote", selection: $name) {
                Text("All Remotes").tag("")
                ForEach(store.managedRemotes) { Text($0.name).tag($0.name) }
            }
            if !name.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Branch").font(.callout)
                    TextField("Branch", text: $branch, prompt: Text("All Branches"))
                        .help("Enter a branch name to fetch only that branch.")
                }
            }
            Text("Fetch updates remote-tracking references without merging or changing your working files.")
                .font(.callout).foregroundStyle(.secondary)

            DisclosureGroup("Advanced Options", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 11) {
                    Picker("Tags", selection: $options.tags) {
                        Text("Default").tag(FetchOptions.Tags.configured)
                        Text("Skip Automatic Tags").tag(FetchOptions.Tags.skip)
                        Text("Fetch All Tags").tag(FetchOptions.Tags.all)
                    }
                    Picker("Time Limit", selection: $options.timeLimit) {
                        ForEach(FetchOptions.TimeLimit.allCases, id: \.self) { limit in
                            Text(Duration.seconds(limit.rawValue * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide)))
                                .tag(limit)
                        }
                    }
                    Toggle("Fetch Submodule Updates", isOn: $options.recurseSubmodules)
                    Toggle("Prune Deleted Remote Branches", isOn: $options.prune)
                        .disabled(branchName != nil)
                        .help("Pruning is available when fetching all configured branches.")
                    Toggle("Use HTTP/1.1", isOn: $options.useHTTP11)
                        .help("Try this for HTTPS transfers that repeatedly disconnect. This only applies to this fetch.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12).padding(.top, 10)
            }

            ManagementFooter(title: "Fetch", disabled: !store.canUseRepository || store.managedRemotes.isEmpty || (!name.isEmpty && selectedRemote == nil)) {
                var request = options
                request.branch = branchName
                if branchName != nil { request.prune = false }
                store.runRemoteFetch(selectedRemote, options: request)
                dismiss()
            }
        }.padding(24).frame(width: 520)
    }
}

extension RepositoryStore {
    func runRemoteFetch(_ remote: RemoteConfiguration?, options: FetchOptions) {
        guard canUseRepository else { return }
        perform("Fetching…", feedback: .fetch) { try await $0.fetch(remote, options: options) }
    }

    func runRemoteFetch(_ remote: RemoteConfiguration?, prune: Bool, tags: Bool) {
        var options = FetchOptions()
        options.prune = prune
        if tags { options.tags = .all }
        runRemoteFetch(remote, options: options)
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
