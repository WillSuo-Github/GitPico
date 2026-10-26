import AppKit
import GitCore
import SwiftUI

struct AuthenticationSettingsView: View {
    @Bindable var store: RepositoryStore
    @State private var provider = HostingProvider.github
    @State private var host = "github.com"
    @State private var username = ""
    @State private var token = ""
    @State private var message: String?
    @State private var busy = false
    @State private var removing: AuthenticationProfile?
    @State private var editing: AuthenticationProfile?
    var body: some View {
        Form {
            Section {
                Text("Use your existing SSH agent and Git credential helpers, or connect an HTTPS account with a personal access token stored in Keychain.").font(.callout).foregroundStyle(.secondary)
                if let root = store.snapshot?.root {
                    Picker("This repository", selection: Binding<UUID?>(get: { store.authentication.profile(for: root)?.id }, set: { id in run { try store.authentication.assign(id, to: root); updateContexts() } })) {
                        Text("System Git / SSH").tag(nil as UUID?)
                        ForEach(store.authentication.profiles) { profile in Text(profile.label).tag(Optional(profile.id)) }
                    }.disabled(store.networkActivity?.runningCount ?? 0 > 0)
                    Text(root.lastPathComponent + " · HTTPS profiles apply only to their exact host. SSH remotes continue to use system SSH.").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Connection") }
            Section("Connected HTTPS Accounts") {
                if store.authentication.profiles.isEmpty { Text("No saved accounts").foregroundStyle(.secondary) }
                ForEach(store.authentication.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading) { Text(profile.username).fontWeight(.medium); Text(profile.provider.rawValue + " · " + profile.host).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if profile.provider != .generic { Button("Verify") { verify(profile) }.disabled(busy) }
                        Button("Update Token…") { editing = profile; provider = profile.provider; host = profile.host; username = profile.username; token = "" }.disabled(busy || store.networkActivity?.runningCount ?? 0 > 0)
                        Button("Remove…", role: .destructive) { removing = profile }.disabled(busy || store.networkActivity?.runningCount ?? 0 > 0)
                    }
                }
            }
            Section {
                Picker("Service", selection: $provider) { ForEach(HostingProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .onChange(of: provider) { if editing == nil { host = provider == .github ? "github.com" : provider == .gitlab ? "gitlab.com" : "" } }.disabled(editing != nil)
                TextField("Host", text: $host, prompt: Text("git.example.com")).disabled(editing != nil)
                TextField("Username", text: $username).disabled(editing != nil)
                SecureField("Personal access token", text: $token).privacySensitive()
                HStack {
                    Text("The token is never saved in repository config or activity logs.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if editing != nil { Button("Cancel Update") { editing = nil; token = ""; username = "" } }
                    Button(editing == nil ? "Save to Keychain" : "Update in Keychain") {
                        run {
                            if let editing { try store.authentication.replaceToken(editing, token: token) }
                            else { _ = try store.authentication.add(provider: provider, host: host, username: username, token: token, for: store.snapshot?.root) }
                            editing = nil; token = ""; updateContexts(); message = "Account saved. Verify it, then test access to your remote."
                        }
                    }.disabled(busy || token.isEmpty || username.isEmpty || host.isEmpty || store.networkActivity?.runningCount ?? 0 > 0)
                }
            } header: { Text("Connect an Account") } footer: { Text("Use a token authorized for the repositories you need. Account verification checks identity; Test Remote checks read access. Push permissions are validated by the server during Push.").font(.caption) }
            if provider == .github {
                Link("GitHub token setup and permissions", destination: URL(string: "https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens")!)
            } else if provider == .gitlab {
                Link("GitLab token setup and permissions", destination: URL(string: "https://docs.gitlab.com/user/profile/personal_access_tokens/")!)
            }
            Section("Test and Diagnose") {
                if busy { ProgressView().controlSize(.small) }
                if let message { Text(message).font(.callout).textSelection(.enabled) }
                if let result = store.connectionTestMessage { Text(result).font(.callout).textSelection(.enabled) }
                if store.isBusy { ProgressView(store.activity).controlSize(.small) }
                if let error = store.authentication.error {
                    HStack { Text(error).foregroundStyle(Pico.deletion).font(.caption); Button("Reload") { store.authentication.reload(); updateContexts() } }
                }
                ForEach(store.managedRemotes) { remote in
                    Button("Test Remote “" + remote.name + "”") { store.configureNetworkContext(); store.testRemote(remote.name) }.disabled(store.isBusy)
                }
                Button("Inspect System Authentication") { inspectSystem() }.disabled(busy || store.repository == nil)
                HStack {
                    Button("View Network Activity") {
                        if store.showingAuthentication { store.networkAfterAuthentication = true; store.showingAuthentication = false }
                        else { store.showingNetworkActivity = true }
                    }
                    Button("Reload Account Settings") { store.authentication.reload(); updateContexts() }.disabled(busy || store.networkActivity?.runningCount ?? 0 > 0)
                }
                Text("Encrypted SSH keys must be unlocked in your SSH agent. Verify unknown host fingerprints before adding them to known_hosts. GitPico does not weaken SSH host verification.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
            .confirmationDialog("Remove this account and its saved token?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Remove Account", role: .destructive) { if let removing { run { try store.authentication.remove(removing); updateContexts() } }; removing = nil }
            }
    }
    private func run(_ action: () throws -> Void) { do { try action() } catch { message = error.localizedDescription } }
    private func updateContexts() {
        if let workspace = store.workspace { for tab in workspace.tabs { tab.store.configureNetworkContext() } }
        else { store.configureNetworkContext() }
    }
    private func verify(_ profile: AuthenticationProfile) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let vault = store.authentication.vault
                let credential = try await Task.detached { try vault.read(profile.id) }.value
                let result = try await HostingAccountClient.verify(profile, credential: credential)
                message = "Signed in as " + result.login + ". " + result.description
            } catch { message = GitLogRedaction.clean(error.localizedDescription) }
        }
    }
    private func inspectSystem() {
        guard let repository = store.repository else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let output = try await GitNetworkContexts.$current.withValue(GitNetworkContext { _ in }) {
                    try await GitProcess.run(["config", "--get-all", "credential.helper"], at: repository.root, allowed: [0,1])
                }
                let helpers = GitLogRedaction.clean(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
                let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] == nil ? "SSH_AUTH_SOCK is not set for this app. SSH may still use keys configured in your system SSH setup." : "SSH_AUTH_SOCK is set. This does not verify agent connectivity or unlocked keys; use Test Remote to check access."
                message = "Credential helpers: " + (helpers.isEmpty ? "none configured" : helpers) + "\n" + agent
            } catch { message = error.localizedDescription }
        }
    }
}

struct AuthenticationPanel: View {
    let store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { SheetTitle("Authentication", icon: "person.badge.key"); Spacer() }.padding(20)
            AuthenticationSettingsView(store: store)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).padding(12)
        }.frame(width: 740, height: 650)
    }
}
