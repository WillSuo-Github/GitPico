import GitCore
import SwiftUI

struct CommitWorkflowSettingsView: View {
    @State private var library = CommitWorkflowLibrary.shared
    @State private var template: CommitTemplate?
    @State private var identity: CommitIdentityProfile?
    @State private var error: String?
    var body: some View {
        Form {
            Section("Commit Templates") {
                ForEach(library.templates) { item in
                    HStack { Text(item.name); Spacer(); Button("Edit…") { template = item }; Button("Delete", role: .destructive) { edit { try library.remove(template: item.id) } } }
                }
                Button("New Template…") { template = CommitTemplate(name: "New Template", text: "") }
                Text("Templates are shared across repositories. In the commit options menu, preview a saved template or the repository's Git commit.template before inserting it.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Commit Identities") {
                ForEach(library.identities) { item in
                    HStack { VStack(alignment: .leading) { Text(item.label); Text(item.name + " <" + item.email + ">").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Edit…") { identity = item }; Button("Delete", role: .destructive) { edit { try library.remove(identity: item.id) } } }
                }
                Button("New Identity…") { identity = CommitIdentityProfile(label: "Personal", name: "", email: "") }
                Text("Selecting a profile applies it to the current repository's local Git configuration. Other repositories retain their identities.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = error ?? library.error { Text(error).foregroundStyle(Pico.deletion).textSelection(.enabled) }
        }.formStyle(.grouped)
        .sheet(item: $template) { item in CommitTemplateEditor(template: item, library: library) }
        .sheet(item: $identity) { item in CommitIdentityEditor(profile: item, library: library) }
    }
    private func edit(_ action: () throws -> Void) { do { try action(); error = nil } catch { self.error = error.localizedDescription } }
}

private struct CommitTemplateEditor: View {
    @State var template: CommitTemplate
    let library: CommitWorkflowLibrary
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetTitle("Commit Template")
            TextField("Template name", text: $template.name)
            TextEditor(text: $template.text).font(.system(.body, design: .monospaced)).frame(height: 220).accessibilityLabel("Template message")
            if let error { Text(error).foregroundStyle(Pico.deletion) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { do { try library.save(template: template); dismiss() } catch { self.error = error.localizedDescription } }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 560)
    }
}
private struct CommitIdentityEditor: View {
    @State var profile: CommitIdentityProfile
    let library: CommitWorkflowLibrary
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetTitle("Commit Identity")
            TextField("Profile label", text: $profile.label)
            TextField("Name", text: $profile.name)
            TextField("Email", text: $profile.email)
            if let error { Text(error).foregroundStyle(Pico.deletion) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { do { try library.save(identity: profile); dismiss() } catch { self.error = error.localizedDescription } }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480)
    }
}

struct CommitTemplateInsertion: Identifiable { let id = UUID(); let name: String; let text: String; let root: URL? }
struct CommitTemplateInsertionView: View {
    let store: RepositoryStore
    let insertion: CommitTemplateInsertion
    @State private var replacing = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetTitle(insertion.name, icon: "doc.text")
            ScrollView { Text(insertion.text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 240)
            Text("Append keeps your current draft. Replace uses the first line as the summary and the remaining text as the description.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                Button("Append to Description") { store.commitBody += (store.commitBody.isEmpty ? "" : "\n\n") + insertion.text; dismiss() }
                Button("Replace Draft…") { replacing = true }
            }.disabled(store.isBusy || store.snapshot?.root != insertion.root)
        }.padding(24).frame(width: 580)
        .confirmationDialog("Replace the current commit draft?", isPresented: $replacing) {
            Button("Replace Draft", role: .destructive) {
                guard !store.isBusy, store.snapshot?.root == insertion.root else { return }
                let lines = insertion.text.components(separatedBy: "\n")
                store.commitSubject = lines.first ?? ""; store.commitBody = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines); dismiss()
            }
        }
    }
}

struct SignatureVerificationView: View {
    let repository: GitRepository
    let revision: String
    var tag = false
    @State private var result: GitSignature?
    @State private var error: String?
    @State private var checking = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(result?.state.rawValue ?? "Signature not checked", systemImage: "signature")
                Spacer()
                Button(checking ? "Verifying…" : "Verify Signature") {
                    checking = true
                    Task {
                        defer { checking = false }
                        do { result = try await repository.signature(of: revision, tag: tag); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(checking)
            }
            if let result {
                if !result.signer.isEmpty { Text(result.signer).textSelection(.enabled) }
                if !result.fingerprint.isEmpty || !result.key.isEmpty { Text(result.fingerprint.isEmpty ? result.key : result.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                if !result.diagnostic.isEmpty { Text(result.diagnostic).textSelection(.enabled) }
                if result.state == .unverifiable { Text("Check the repository's GPG/SSH verifier and trusted keys. A missing verifier or key does not establish an invalid signature.").foregroundStyle(.secondary) }
            }
            if let error { Text(error).foregroundStyle(Pico.deletion).textSelection(.enabled) }
        }.font(.caption).id(revision)
    }
}
