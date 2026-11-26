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
            ManagementFooter(title: action == .edit ? (remote == nil ? "Add Remote" : "Save Remote") : title, disabled: store.isBusy || store.isFetching || (action != .remove && name.isEmpty) || (action == .edit && fetch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), destructive: action == .remove) {
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
    @AppStorage("fetch.allRemotes") private var savedAllRemotes = true
    @State private var allRemotesForThisSheet = false
    private let usesSavedScope: Bool
    private let options: FetchOptions
    @Environment(\.dismiss) private var dismiss

    init(store: RepositoryStore, initialRemote: RemoteConfiguration?, mode: FetchReviewMode) {
        self.store = store
        usesSavedScope = initialRemote == nil
        let defaultRemote = store.managedRemotes.first { $0.name == "origin" } ?? store.managedRemotes.first
        _name = State(initialValue: initialRemote?.name ?? defaultRemote?.name ?? "")
        var options = FetchOptions()
        if mode == .largeTransfer { options.tags = .skip }
        self.options = options
    }

    private var selectedRemote: RemoteConfiguration? { store.managedRemotes.first { $0.name == name } }

    var body: some View {
        let scope = usesSavedScope ? $savedAllRemotes : $allRemotesForThisSheet
        let allRemotes = scope.wrappedValue
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle("Fetch Remote Repository", icon: "arrow.down.circle")
            Picker("Remote", selection: $name) {
                ForEach(store.managedRemotes) { Text($0.name).tag($0.name) }
            }
            .disabled(allRemotes)
            Toggle("All Remotes", isOn: scope)
                .toggleStyle(.checkbox)
            Text("Fetch updates remote-tracking references without merging or changing your working files.")
                .font(.callout).foregroundStyle(.secondary)

            ManagementFooter(title: "Fetch", disabled: !store.canFetch || store.managedRemotes.isEmpty || (!allRemotes && selectedRemote == nil)) {
                store.runRemoteFetch(allRemotes ? nil : selectedRemote, options: options)
                dismiss()
            }
        }.padding(24).frame(width: 460)
    }
}

extension RepositoryStore {
    func runRemoteFetch(_ remote: RemoteConfiguration?, options: FetchOptions) {
        guard canFetch, let repository, let snapshot else { return }
        let token = repositoryToken
        let label: String
        if let remote {
            label = String(localized: "Fetching…") + " · " + remote.name
        } else if snapshot.remotes.count == 1, let single = snapshot.remotes.first {
            label = String(localized: "Fetching…") + " · " + single
        } else {
            label = String(localized: "Fetching…")
        }
        isManualFetching = true
        beginFetchFeedback(repository: snapshot.root.path, activity: label)
        fetchTask = Task {
            var fetchError: String?
            do {
                try await repository.fetch(remote, options: options)
            } catch {
                fetchError = error.localizedDescription
            }
            guard token == repositoryToken else { return }
            if let fetchError {
                fetchFeedback?.failure = fetchError
                self.error = fetchError
            } else if remote == nil {
                let commonDirectory = try? await repository.commonDirectory().path
                guard token == repositoryToken else { return }
                workspace?.recordBackgroundFetch(for: snapshot.root.path, commonDirectory: commonDirectory)
            }
            fetchFeedback?.isRefreshing = true
            if let refreshError = await refreshAfterFetch(expectedToken: token) {
                guard token == repositoryToken else { return }
                let combined = [fetchFeedback?.failure, refreshError].compactMap { $0 }.joined(separator: "\n\n")
                fetchFeedback?.failure = combined
                self.error = [self.error, refreshError].compactMap { $0 }.joined(separator: "\n\n")
            }
            guard token == repositoryToken else { return }
            isManualFetching = false
            finishFetchFeedback()
        }
    }

    func runRemoteFetch(_ remote: RemoteConfiguration?, prune: Bool, tags: Bool) {
        var options = FetchOptions()
        options.prune = prune
        if tags { options.tags = .all }
        runRemoteFetch(remote, options: options)
    }

    func runRemotePush(_ preview: RemotePushPreview) {
        guard !isFetching else { return }
        perform(preview.deletes ? "Deleting remote reference…" : "Pushing…", feedback: .push) { try await $0.executePush(preview) }
    }

    /// A normal push checks and writes in one operation; it never enables force or deletion.
    func runRemotePush(remote: RemoteConfiguration, source: Reference, destination: String, setUpstream: Bool, pushURL: String) {
        guard !isFetching else { return }
        perform("Pushing…", feedback: .push) { repository in
            let checked = try await repository.pushPreview(remote: remote, source: source, destination: destination, setUpstream: setUpstream, pushURL: pushURL)
            try await repository.executePush(checked)
        }
    }
}
