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
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(store.title, systemImage: "gearshape").font(.system(size: 12))
                Spacer()
                Picker("Settings", selection: $store.settingsTab) { Text("General").tag("General"); Text("Remotes").tag("Remotes"); Text("Ignores").tag("Ignores"); Text("Excludes").tag("Excludes"); Text("Git LFS").tag("Git LFS"); Text("Git Flow").tag("Git Flow") }.pickerStyle(.segmented).labelsHidden().frame(width: 590)
            }.padding(.horizontal, 16).frame(height: 40).background(.bar)
            Divider()
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
            description = store.configuration?.description ?? ""
            signCommits = store.configuration?.signCommits ?? false
            signingKey = store.configuration?.signingKey ?? ""
        }
    }
    var general: some View {
        Form {
            Section("GENERAL") {
                LabeledContent("Name", value: store.title)
                LabeledContent("Path", value: store.snapshot?.root.path ?? "").textSelection(.enabled)
                TextField("User Description", text: $description)
                TextField("Committer Name", text: $name)
                TextField("Committer Email", text: $email)
            }
            Section("SIGNING") {
                Toggle("Sign Commits", isOn: $signCommits)
                TextField("Signing Key", text: $signingKey)
                Text("Uses the repository's existing GPG or SSH signing setup.").font(.caption).foregroundStyle(.secondary)
            }
            Section("REMOTES") {
                ForEach(store.managedRemotes) { remote in
                    LabeledContent(remote.name) { VStack(alignment: .trailing, spacing: 4) { Text(remote.fetchURL); Text(remote.pushURL).foregroundStyle(.secondary) }.textSelection(.enabled) }
                }
                if store.managedRemotes.isEmpty { Text("No remotes configured.").foregroundStyle(.secondary) }
                Button("Manage Remotes…") { store.settingsTab = "Remotes" }
            }
            Button("Save for This Repository") {
                let identityName = name; let identityEmail = email; let body = description; let signing = signCommits; let key = signingKey
                store.perform("Saving repository settings…") { try await $0.saveConfiguration(name: identityName, email: identityEmail, description: body, signCommits: signing, signingKey: key) }
            }.disabled(store.isBusy || store.configuration == nil || name.isEmpty || email.isEmpty)
        }.formStyle(.grouped).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
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
            Text(kind == .ignores ? "Shared ignore rules (.gitignore)" : "Local exclude rules (info/exclude)").font(.headline)
            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(kind == .ignores ? "These rules are versioned with your repository." : "These rules affect this working directory and are not committed.").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).border(.quaternary)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Reload") { Task { await load() } }.disabled(isSaving)
                Spacer()
                Button("Save") {
                    guard let original, let repository = store.repository else { return }
                    let submitted = text
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        do { try await repository.writeIgnoreFile(kind, text: submitted, expected: original); self.original = submitted; error = nil; store.refresh() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(original == nil || text == original || isSaving || store.isBusy)
            }
        }.padding(22).task { await load() }
    }
    func load() async {
        guard let repository = store.repository else { return }
        do { path = try await repository.ignoreFileURL(kind).path; text = try await repository.readIgnoreFile(kind); original = text; error = nil }
        catch { self.error = error.localizedDescription; original = nil }
    }
}
