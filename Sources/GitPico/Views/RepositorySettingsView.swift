import AppKit
import GitCore
import SwiftUI

struct RepositorySettingsView: View {
    @Bindable var store: RepositoryStore
    var tab: String { store.settingsTab }
    @State private var name = ""
    @State private var email = ""
    @State private var description = ""
    @State private var signCommits = false
    @State private var signingKey = ""
    @State private var defaultDescription: String?
    static let gitDefaultDescription = "Unnamed repository; edit this file 'description' to name the repository."
    var body: some View {
        VStack(spacing: 0) {
            PaneBar(title: "Repository Settings", subtitle: store.title, icon: "gearshape") {
                Picker("Settings", selection: $store.settingsTab) { Text("General").tag("General"); Text("Remotes").tag("Remotes"); Text("Ignores").tag("Ignores"); Text("Excludes").tag("Excludes"); Text("Git LFS").tag("Git LFS"); Text("Git Flow").tag("Git Flow") }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if tab == "General" { general }
            else if tab == "Remotes" { RemoteSettingsPane(store: store) }
            else if tab == "Git LFS" { LFSSettingsPane(store: store) }
            else if tab == "Git Flow" { GitFlowSettingsPane(store: store) }
            else { IgnoreFileEditor(store: store, kind: tab == "Ignores" ? .ignores : .excludes).id(tab) }
        }
        .task {
            await store.loadConfiguration()
            name = store.configuration?.identity.name ?? ""
            email = store.configuration?.identity.email ?? ""
            let loaded = store.configuration?.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Git's template text is a placeholder, not a description the user wrote.
            defaultDescription = loaded == Self.gitDefaultDescription ? loaded : nil
            description = defaultDescription == nil ? loaded : ""
            signCommits = store.configuration?.signCommits ?? false
            signingKey = store.configuration?.signingKey ?? ""
        }
    }
    var general: some View {
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
                TextField("Description", text: $description, prompt: Text("Optional, shown by tools such as gitweb"))
            }
            Section {
                TextField("Name", text: $name, prompt: Text("Committer name"))
                TextField("Email", text: $email, prompt: Text("name@example.com"))
            } header: { Text("Commit Identity") } footer: { Text("Saved in this repository's local Git config and used instead of your global identity.").font(.caption).foregroundStyle(.secondary) }
            Section {
                Toggle("Sign Commits", isOn: $signCommits)
                TextField("Signing Key", text: $signingKey, prompt: Text("GPG key ID or SSH key path"))
            } header: { Text("Signing") } footer: { Text("Uses the repository's existing GPG or SSH signing setup.").font(.caption).foregroundStyle(.secondary) }
            Section {
                ForEach(store.managedRemotes) { remote in
                    LabeledContent { Text(remote.fetchURL).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled) } label: { Label(remote.name, systemImage: "cloud") }
                }
                if store.managedRemotes.isEmpty { Text("No remotes configured.").foregroundStyle(.secondary) }
            } header: {
                HStack { Text("Remotes"); Spacer(); Button("Manage…") { store.settingsTab = "Remotes" }.buttonStyle(.link).font(.caption) }
            }
            HStack {
                Spacer()
                Button("Save Changes") {
                    let identityName = name; let identityEmail = email; let body = description.isEmpty ? (defaultDescription ?? "") : description; let signing = signCommits; let key = signingKey
                    store.perform("Saving repository settings…") { try await $0.saveConfiguration(name: identityName, email: identityEmail, description: body, signCommits: signing, signingKey: key) }
                }.buttonStyle(.borderedProminent).disabled(store.isBusy || store.configuration == nil || name.isEmpty || email.isEmpty)
            }
        }.formStyle(.grouped).frame(maxWidth: 760).frame(maxWidth: .infinity)
    }
}

struct IgnoreFileEditor: View {
    let store: RepositoryStore
    let kind: GitRepository.IgnoreFile
    @State private var text = ""
    @State private var original: String?
    @State private var path = ""
    @State private var error: String?
    @State private var isSaving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind == .ignores ? "Shared ignore rules" : "Local exclude rules").font(.system(size: 15, weight: .semibold))
                    Text(kind == .ignores ? "Versioned in .gitignore and shared with everyone who clones the repository." : "Stored in .git/info/exclude; affects only this working directory and is never committed.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Chip(text: kind == .ignores ? ".gitignore" : "info/exclude", icon: "doc.text", tint: .secondary, monospaced: true).help(path)
            }
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Reload") { Task { await load() } }.disabled(isSaving)
                Spacer()
                if original != nil, text != original { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
                Button("Save") {
                    guard let original, let repository = store.repository else { return }
                    let submitted = text
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        do { try await repository.writeIgnoreFile(kind, text: submitted, expected: original); self.original = submitted; error = nil; store.refresh() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(original == nil || text == original || isSaving || store.isBusy)
            }
        }.padding(22).task { await load() }
    }
    func load() async {
        guard let repository = store.repository else { return }
        do { path = try await repository.ignoreFileURL(kind).path; text = try await repository.readIgnoreFile(kind); original = text; error = nil }
        catch { self.error = error.localizedDescription; original = nil }
    }
}
