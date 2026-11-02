import AppKit
import GitCore
import SwiftUI

struct RepositorySettingsView: View {
    @Bindable var store: RepositoryStore
    let identityLibrary: CommitWorkflowLibrary
    @State private var draft: RepositorySettingsDraft
    @State private var confirmsClose = false
    @Environment(\.dismiss) private var dismiss
    init(store: RepositoryStore, draft: RepositorySettingsDraft = RepositorySettingsDraft(), identityLibrary: CommitWorkflowLibrary = .shared) {
        self.store = store; _draft = State(initialValue: draft)
        self.identityLibrary = identityLibrary
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape").foregroundStyle(.tint).font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repository Settings").font(.system(size: 16, weight: .semibold))
                    Text(store.repositoryDisplayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: requestClose).keyboardShortcut(.cancelAction).disabled(draft.saving || (store.isBusy && !store.isFetching))
            }.padding(20)
            Picker("Settings", selection: $store.settingsTab) {
                Text("General").tag("General"); Text("Remotes").tag("Remotes"); Text("Ignores").tag("Ignores")
                Text("Excludes").tag("Excludes"); Text("Git LFS").tag("Git LFS"); Text("Git Flow").tag("Git Flow")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            Group {
                switch store.settingsTab {
                case "Remotes": RemoteSettingsPane(store: store)
                case "Git LFS": LFSSettingsPane(store: store)
                case "Git Flow": GitFlowSettingsPane(store: store)
                case "Ignores": IgnoreFileEditor(store: store, draft: draft.ignores)
                case "Excludes": IgnoreFileEditor(store: store, draft: draft.excludes)
                default:
                    if let values = Binding($draft.general) { general(values) }
                    else { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(draft.saving)
            Divider()
            HStack {
                if draft.hasChanges { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if draft.saving { ProgressView().controlSize(.small) }
                Button("Save Changes") { Task { _ = await draft.save(in: store) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut("s")
                    .disabled(!draft.canSave || store.isBusy)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }.frame(width: 850, height: 660)
        .interactiveDismissDisabled(draft.hasChanges || draft.saving)
        .alert("Save changes before closing?", isPresented: $confirmsClose) {
            Button("Save and Close") { Task { if await draft.save(in: store) { dismiss() } } }.disabled(!draft.canSave)
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) { store.settingsNavigationRequest = nil }
        } message: { Text("Your unsaved repository settings will be discarded.") }
        .task {
            guard draft.general == nil else { return }
            let token = store.repositoryToken
            await store.loadConfiguration()
            if !Task.isCancelled, token == store.repositoryToken, let configuration = store.configuration { draft.load(configuration) }
        }
        .onChange(of: store.settingsNavigationRequest) { if store.settingsNavigationRequest != nil { requestClose() } }
        .onChange(of: store.isBusy) { if !store.isBusy { store.requestDeferredMetadata(.repositorySettings) } }
    }
    private func requestClose() {
        guard !draft.saving else { return }
        if draft.hasChanges { confirmsClose = true } else { dismiss() }
    }
    func general(_ values: Binding<RepositoryGeneralSettings>) -> some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    RepositoryGlyph(name: store.workspace?.tab(for: store)?.title ?? store.title, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.workspace?.tab(for: store)?.title ?? store.title).font(.system(size: 15, weight: .semibold))
                        Text(Pico.abbreviated(store.snapshot?.root.path ?? "")).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Reveal in Finder") { if let root = store.snapshot?.root { NSWorkspace.shared.activateFileViewerSelecting([root]) } }.controlSize(.small)
                }.padding(.vertical, 4)
                TextField("Description", text: Binding(get: { values.description.wrappedValue == RepositorySettingsDraft.gitDefaultDescription ? "" : values.description.wrappedValue }, set: { values.description.wrappedValue = $0 }), prompt: Text("Optional, shown by tools such as gitweb"))
            }
            Section {
                RepositoryIdentityFields(values: values, library: identityLibrary)
            } header: { Text("Commit Identity") } footer: { Text("Saved in this repository's local Git config and used instead of your global identity.").font(.caption).foregroundStyle(.secondary) }
            Section {
                Toggle("Sign Commits", isOn: values.signCommits)
                TextField("Signing Key", text: values.signingKey, prompt: Text("GPG key ID or SSH key path"))
            } header: { Text("Signing") } footer: { Text("Uses the repository's existing GPG or SSH signing setup.").font(.caption).foregroundStyle(.secondary) }
            Section {
                ForEach(store.managedRemotes) { remote in
                    LabeledContent { Text(remote.fetchURL).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled) } label: { Label(remote.name, systemImage: "cloud") }
                }
                if store.managedRemotes.isEmpty { Text("No remotes configured.").foregroundStyle(.secondary) }
            } header: {
                HStack { Text("Remotes"); Spacer(); Button("Manage…") { store.settingsTab = "Remotes" }.buttonStyle(.link).font(.caption) }
            }
        }.formStyle(.grouped).frame(maxWidth: 760).frame(maxWidth: .infinity)
    }
}

struct IgnoreFileEditor: View {
    let store: RepositoryStore
    @Bindable var draft: IgnoreSettingsDraft
    var kind: GitRepository.IgnoreFile { draft.kind }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind == .ignores ? "Shared ignore rules" : "Local exclude rules").font(.system(size: 15, weight: .semibold))
                    Text(kind == .ignores ? "Versioned in .gitignore and shared with everyone who clones the repository." : "Stored in .git/info/exclude; affects only this working directory and is never committed.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Chip(text: kind == .ignores ? ".gitignore" : "info/exclude", icon: "doc.text", tint: .secondary, monospaced: true).help(draft.path)
            }
            TextEditor(text: $draft.text).environment(\.layoutDirection, .leftToRight).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .disabled(draft.original == nil || draft.loading || store.isBusy)
            if let error = draft.error { Text(error).font(.caption).foregroundStyle(Pico.deletion).textSelection(.enabled) }
            HStack {
                Button("Reload") { Task { if let repository = store.repository { await draft.load(from: repository) } } }
                    .disabled(draft.loading || store.isBusy || draft.isDirty)
                Spacer()
            }
        }.padding(22).task {
            if draft.original == nil, let repository = store.repository { await draft.load(from: repository) }
        }
    }
}
