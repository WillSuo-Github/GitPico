import SwiftUI

struct CommitIdentitiesView: View {
    let library: CommitWorkflowLibrary
    @State private var editing: CommitIdentityProfile?
    @State private var deleting: CommitIdentityProfile?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Commit Identities").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Save identities such as Personal and Work, then choose one for each repository.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(library.identities) { profile in
                    HStack(spacing: 10) {
                        AuthorAvatar(name: profile.name, size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.label).fontWeight(.medium)
                            Text("\(profile.name) <\(profile.email)>").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Edit…") { editing = profile }
                        Button("Delete", role: .destructive) { deleting = profile }
                    }.padding(.vertical, 5)
                }
            }.listStyle(.inset).frame(minHeight: 180)
                .overlay {
                    if library.identities.isEmpty {
                        ContentUnavailableView("No saved identities", systemImage: "person.crop.circle", description: Text("Add a name and email to reuse across repositories."))
                    }
                }
            Text("Editing or deleting a saved identity leaves identities already applied to repositories unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure = failure ?? library.error { Text(failure).font(.caption).foregroundStyle(Pico.deletion).textSelection(.enabled) }
            Button("New Identity…") { editing = CommitIdentityProfile(label: "", name: "", email: "") }.buttonStyle(.borderedProminent)
        }.padding(20).frame(width: 600, height: 380)
        .sheet(item: $editing) { CommitIdentityEditor(profile: $0, library: library) }
        .alert("Delete saved identity?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                guard let deleting else { return }
                do { try library.remove(identity: deleting.id); failure = nil } catch { failure = error.localizedDescription }
                self.deleting = nil
            }
        } message: { Text("This removes the saved profile. Existing repository identities are kept.") }
    }
}

struct RepositoryIdentityFields: View {
    @Binding var values: RepositoryGeneralSettings
    var library: CommitWorkflowLibrary = .shared
    @State private var managing = false
    @State private var saving: CommitIdentityProfile?

    private var selected: UUID? { library.identities.first { $0.matches(name: values.name, email: values.email) }?.id }
    var body: some View {
        Picker("Saved Identity", selection: Binding<UUID?>(get: { selected }, set: { id in
            if let profile = library.identities.first(where: { $0.id == id }) { values.useIdentity(profile) }
        })) {
            if selected == nil { Text("Custom Identity").tag(Optional<UUID>.none) }
            ForEach(library.identities) { profile in
                Text("\(profile.label) · \(profile.email)").tag(Optional(profile.id))
            }
        }
        TextField("Name", text: $values.name, prompt: Text("Committer name"))
        TextField("Email", text: $values.email, prompt: Text("name@example.com"))
        HStack {
            Button("Manage Identities…") { managing = true }
            Spacer()
            Button("Save as Identity…") { saving = CommitIdentityProfile(label: "", name: values.name, email: values.email) }
                .disabled(values.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || values.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.controlSize(.small)
        .sheet(isPresented: $managing) { CommitIdentitiesView(library: library) }
        .sheet(item: $saving) { profile in
            CommitIdentityEditor(profile: profile, library: library) { values.useIdentity($0) }
        }
    }
}

struct CommitIdentityMenu: View {
    let store: RepositoryStore
    var library: CommitWorkflowLibrary = .shared
    @State private var managing = false
    private var selected: CommitIdentityProfile? {
        library.identities.first { $0.matches(name: store.snapshot?.identity.name ?? "", email: store.snapshot?.identity.email ?? "") }
    }
    private var title: String {
        if let selected { return selected.label + " · " + selected.name }
        return store.snapshot?.identity.name.nilIfEmpty ?? String(localized: "No identity")
    }
    private var tooltip: String {
        let name = store.snapshot?.identity.name ?? "", email = store.snapshot?.identity.email ?? ""
        return name + " <" + email + ">\n" + String(localized: "Choose the commit identity for this repository")
    }
    var body: some View {
        HStack(spacing: 5) {
            AuthorAvatar(name: store.snapshot?.identity.name.nilIfEmpty ?? "?", size: 18)
            Menu { items } label: { Text(title).lineLimit(1).truncationMode(.tail) }
                .menuStyle(.borderlessButton).font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(tooltip)
        .sheet(isPresented: $managing) { CommitIdentitiesView(library: library) }
    }
    @ViewBuilder private var items: some View {
        if !library.identities.isEmpty {
            Section("Commit Identities") {
                ForEach(library.identities) { profile in
                    Button { store.saveIdentity(name: profile.name, email: profile.email) } label: {
                        let current = profile.matches(name: store.snapshot?.identity.name ?? "", email: store.snapshot?.identity.email ?? "")
                        Label("\(profile.label) · \(profile.name) <\(profile.email)>", systemImage: current ? "checkmark" : "person")
                    }.disabled(store.isBusy)
                }
            }
            Divider()
        }
        Button("Manage Identities…") { managing = true }
        Button("Repository Settings") { store.navigate(.repositorySettings) }
    }
}
