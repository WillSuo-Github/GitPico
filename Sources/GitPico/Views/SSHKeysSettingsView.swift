import AppKit
import GitCore
import SwiftUI

struct SSHKeysSettingsView: View {
    @State private var keys: [SSHManagedKey] = []
    @State private var name = "gitpico_ed25519"
    @State private var comment = "GitPico"
    @State private var acknowledged = false
    @State private var generating = false
    @State private var busy = false
    @State private var message: String?
    private let manager = SSHKeyManager()
    var body: some View {
        Form {
            Section("SSH Agent and Keys") {
                Text("GitPico uses system SSH host verification and your SSH agent. Only public keys and fingerprints are displayed here.").font(.callout).foregroundStyle(.secondary)
                HStack { Button("Reload Keys") { Task { await reload() } }; Spacer(); Button("Generate Key…") { generating = true } }.disabled(busy)
                ForEach(keys) { key in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(key.publicFile.lastPathComponent).fontWeight(.medium)
                        Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        HStack {
                            Button("Copy Public Key") { Pico.copy(key.publicKey) }
                            Button("Add to SSH Agent") { Task { busy = true; defer { busy = false }; do { try await manager.addToAgent(key); message = String(localized: "Key added to the SSH agent.") } catch { message = error.localizedDescription } } }
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([key.publicFile]) }
                        }.disabled(busy)
                    }.padding(.vertical, 5)
                }
                if keys.isEmpty { Text("No public keys found in ~/.ssh or ~/.ssh/gitpico.").foregroundStyle(.secondary) }
                HStack { Link("GitHub SSH Keys", destination: URL(string: "https://github.com/settings/keys")!); Link("GitLab SSH Keys", destination: URL(string: "https://gitlab.com/-/user_settings/ssh_keys")!) }
                Text("Register a copied public key with your host. Encrypted or hardware-backed keys are unlocked by your system tools; existing keys are never overwritten.").font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption).textSelection(.enabled) }
            }
        }.formStyle(.grouped).task { await reload() }
        .sheet(isPresented: $generating) {
            VStack(alignment: .leading, spacing: 14) {
                SheetTitle("Generate Ed25519 Key", icon: "key")
                TextField("Key name", text: $name); TextField("Comment", text: $comment)
                Text("Creates a new key under ~/.ssh/gitpico with owner-only private-key permissions. This generator creates an unencrypted private key. To use a passphrase or hardware security key, create it with system tools and reload this list.").font(.callout).foregroundStyle(.secondary)
                Toggle("I want to create a key without a passphrase", isOn: $acknowledged)
                if let message { Text(message).font(.caption).foregroundStyle(Pico.warning) }
                HStack { Spacer(); Button("Cancel") { generating = false }; Button("Generate") { Task { busy = true; defer { busy = false }; do { _ = try await manager.generate(name: name, comment: comment); generating = false; acknowledged = false; await reload() } catch { message = error.localizedDescription } } }.disabled(!acknowledged || busy || name.isEmpty) }
            }.padding(24).frame(width: 560)
        }
    }
    private func reload() async { do { keys = try await manager.keys() } catch { message = error.localizedDescription } }
}
