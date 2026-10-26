import SwiftUI

struct UpdatesSettingsView: View {
    let store: RepositoryStore
    @State private var updater = UpdateController.shared
    @State private var diagnosticStatus: String?
    var body: some View {
        Form {
            Section("Software Updates") {
                if let project = updater.githubProject {
                    Text("GitHub Releases · " + project).font(.callout)
                    Picker("Update account", selection: $updater.selectedProfile) {
                        Text("Automatic (one GitHub account)").tag(nil as UUID?)
                        ForEach(store.authentication.profiles.filter { $0.provider == .github && $0.host == "github.com" }) { Text($0.username).tag(Optional($0.id)) }
                    }.disabled(updater.preparing || (updater.configured && !updater.canCheck))
                    Text("Private releases require an account with repository read access. Update archives and feeds are verified with the publisher's Ed25519 key.").font(.caption).foregroundStyle(.secondary)
                }
                Text(updater.status).font(.callout).foregroundStyle(.secondary)
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks).disabled(!updater.configured)
                Button("Check for Updates…", action: updater.check).disabled(!updater.canCheck || updater.preparing)
                if updater.preparing { ProgressView().controlSize(.small) }
            }
            Section("Support") {
                Text("Export app/build and repository state with sanitized recent network diagnostics. File contents, commit messages, account credentials and private keys are excluded.").font(.callout).foregroundStyle(.secondary)
                Button("Export Diagnostics…") { DiagnosticExporter.export(store: store) { diagnosticStatus = $0 } }
                if let diagnosticStatus { Text(diagnosticStatus).font(.caption).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
    }
}
