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
    @State private var oauth = OAuthLoginController()
    @State private var customProvider = OAuthProvider.gitlab
    @State private var customHost = ""
    @State private var customClientID = ""
    var body: some View {
        Form {
            Section {
                Text("Sign in with GitHub or GitLab, connect an HTTPS token, or use your existing system Git and SSH setup. Credentials are stored in Keychain.").font(.callout).foregroundStyle(.secondary)
                if let root = store.snapshot?.root {
                    Picker("This repository", selection: Binding<UUID?>(get: { store.authentication.profile(for: root)?.id }, set: { id in run { try store.authentication.assign(id, to: root); updateContexts() } })) {
                        Text("System Git / SSH").tag(nil as UUID?)
                        ForEach(store.authentication.profiles) { profile in Text(profile.label).tag(Optional(profile.id)) }
                    }.disabled(oauth.isRunning || store.networkActivity?.runningCount ?? 0 > 0)
                    Text(root.lastPathComponent + " · HTTPS profiles apply only to their exact host. SSH remotes continue to use system SSH.").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Connection") }
            Section("Sign In with Your Browser") {
                HStack(spacing: 12) {
                    Button { signIn(.github) } label: { Label("Sign In with GitHub", systemImage: "person.crop.circle.badge.checkmark") }
                    Button { signIn(.gitlab) } label: { Label("Sign In with GitLab", systemImage: "person.crop.circle.badge.checkmark") }
                }.disabled(busy || oauth.isRunning || store.networkActivity?.runningCount ?? 0 > 0)
                Text("GitHub requests repository access (including private repositories) and profile access. GitLab requests profile read access and Git repository read/write access. Review the provider's consent screen before approving.").font(.caption).foregroundStyle(.secondary)
                if oauth.isRunning { HStack { ProgressView().controlSize(.small); Spacer(); Button("Cancel Sign-In") { oauth.cancel() } } }
                if let challenge = oauth.deviceChallenge {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("GitHub one-time code").font(.caption).foregroundStyle(.secondary)
                            Text(challenge.userCode).font(.system(.title2, design: .monospaced).bold()).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Copy Code") { Pico.copy(challenge.userCode) }
                        Link("Open GitHub", destination: challenge.verificationURL)
                    }
                    Text("Enter this code only at " + challenge.verificationURL.absoluteString + ". It expires at " + challenge.expiresAt.formatted(date: .omitted, time: .shortened) + ".").font(.caption).foregroundStyle(.secondary)
                }
                if let message = oauth.message { Text(message).font(.callout).textSelection(.enabled) }
                if let failure = oauth.failure { Text(failure).font(.callout).foregroundStyle(Pico.deletion).textSelection(.enabled) }
            }
            Section("Enterprise and Self-managed OAuth") {
                Picker("Provider", selection: $customProvider) { Text("GitHub Enterprise").tag(OAuthProvider.github); Text("GitLab Self-managed").tag(OAuthProvider.gitlab) }
                TextField("Server hostname", text: $customHost, prompt: Text("git.example.com"))
                TextField("Public OAuth Client ID", text: $customClientID)
                Text("Register a public native OAuth application on this server. GitHub requires Device Flow; GitLab requires PKCE with Confidential disabled.").font(.caption).foregroundStyle(.secondary)
                Text("Callback: gitpico://oauth/" + customProvider.rawValue + "/callback").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Sign In to This Server") {
                    run {
                        let configuration = try OAuthConfiguration(provider: customProvider, host: customHost.trimmingCharacters(in: .whitespacesAndNewlines), clientID: customClientID.trimmingCharacters(in: .whitespacesAndNewlines))
                        oauth.start(configuration, authentication: store.authentication, root: store.snapshot?.root, showDevice: { NSWorkspace.shared.open($0) }, saved: updateContexts)
                    }
                }.disabled(busy || oauth.isRunning || customHost.isEmpty || customClientID.isEmpty)
            }
            Section("Connected HTTPS Accounts") {
                if store.authentication.profiles.isEmpty { Text("No saved accounts").foregroundStyle(.secondary) }
                ForEach(store.authentication.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading) { Text(profile.username).fontWeight(.medium); Text(profile.provider.rawValue + " · " + profile.host + (profile.isOAuth ? " · OAuth" : " · Token")).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if profile.provider != .generic { Button("Verify") { verify(profile) }.disabled(busy || oauth.isRunning) }
                        if profile.isOAuth { Button("Sign In Again…") { reconnect(profile) }.disabled(busy || oauth.isRunning || store.networkActivity?.runningCount ?? 0 > 0) }
                        else { Button("Update Token…") { editing = profile; provider = profile.provider; host = profile.host; username = profile.username; token = "" }.disabled(busy || oauth.isRunning || store.networkActivity?.runningCount ?? 0 > 0) }
                        Button("Remove…", role: .destructive) { removing = profile }.disabled(busy || oauth.isRunning || store.networkActivity?.runningCount ?? 0 > 0)
                    }
                }
                Text("Remove deletes this app's local credential. Revoke the provider grant from your authorized applications to withdraw server access.").font(.caption).foregroundStyle(.secondary)
                HStack { Link("GitHub Authorized Apps", destination: URL(string: "https://github.com/settings/applications")!); Link("GitLab Authorized Apps", destination: URL(string: "https://gitlab.com/-/user_settings/applications")!) }
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
                    }.disabled(busy || oauth.isRunning || token.isEmpty || username.isEmpty || host.isEmpty || store.networkActivity?.runningCount ?? 0 > 0)
                }
            } header: { Text("Personal Access Token · Any HTTPS Server") } footer: { Text("Use a token authorized for the repositories you need. Account verification checks identity; Test Remote checks read access. Push permissions are validated by the server during Push.").font(.caption) }
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
                    Button("Reload Account Settings") { store.authentication.reload(); updateContexts() }.disabled(busy || oauth.isRunning || store.networkActivity?.runningCount ?? 0 > 0)
                }
                Text("Encrypted SSH keys must be unlocked in your SSH agent. Verify unknown host fingerprints before adding them to known_hosts. GitPico does not weaken SSH host verification.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
            .onDisappear { oauth.cancel() }
            .confirmationDialog("Remove this account and its saved token?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Remove Account", role: .destructive) { if let removing { run { try store.authentication.remove(removing); updateContexts() } }; removing = nil }
            }
    }
    private func run(_ action: () throws -> Void) { do { try action() } catch { message = error.localizedDescription } }
    private func signIn(_ provider: OAuthProvider) {
        run {
            let configuration = try OAuthAppCatalog.configuration(provider)
            oauth.start(configuration, authentication: store.authentication, root: store.snapshot?.root, showDevice: { url in NSWorkspace.shared.open(url) }, saved: updateContexts)
        }
    }
    private func reconnect(_ profile: AuthenticationProfile) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let vault = store.authentication.vault
                let credential = try await Task.detached { try vault.read(profile.id) }.value
                guard let existing = credential.oauth?.configuration else { throw GitFailure("This OAuth credential is missing. Remove the account and sign in again.") }
                let configuration = try OAuthConfiguration(provider: existing.provider, host: existing.host, clientID: existing.clientID)
                oauth.start(configuration, authentication: store.authentication, root: nil, reconnecting: profile, showDevice: { url in NSWorkspace.shared.open(url) }, saved: updateContexts)
            } catch { message = GitLogRedaction.clean(error.localizedDescription) }
        }
    }
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
                let credential = profile.isOAuth ? try await OAuthCredentialRefresher.shared.credential(profile.id) : try await Task.detached { try vault.read(profile.id) }.value
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
