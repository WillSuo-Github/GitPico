import GitCore
import SwiftUI

struct ManagementRecoverySheet: View {
    let store: RepositoryStore
    @State private var backups: [ReferenceBackup] = []
    @State private var remotes: [RemovedRemote] = []
    @State private var category = "References"
    @State private var selected: UUID?
    @State private var name = ""
    @State private var failure: String?
    @State private var loading = true
    @Environment(\.dismiss) private var dismiss
    var reference: ReferenceBackup? { backups.first { $0.id == selected } }
    var remote: RemovedRemote? { remotes.first { $0.id == selected } }
    var visible: [ReferenceBackup] { backups.filter { category == "Stashes" ? $0.isStash : !$0.isStash } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recover Deleted Items").font(.title2.bold())
            Text("Recovery records are stored in this repository. Restoring never replaces an existing branch, tag or remote name.").font(.callout).foregroundStyle(.secondary)
            Picker("Kind", selection: $category) { Text("References").tag("References"); Text("Stashes").tag("Stashes"); Text("Remotes").tag("Remotes") }.pickerStyle(.segmented)
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if category == "Remotes" {
                List(selection: $selected) { ForEach(remotes) { backup in
                    VStack(alignment: .leading, spacing: 4) { Text(backup.configuration.name); Text(backup.configuration.fetchURL).font(.caption).foregroundStyle(.secondary); Text(backup.date.formatted()).font(.caption2).foregroundStyle(.secondary) }.tag(backup.id)
                } }.listStyle(.bordered)
            } else {
                List(selection: $selected) { ForEach(visible) { backup in
                    VStack(alignment: .leading, spacing: 4) { Text(backup.title).lineLimit(2); Text("\(backup.hash.prefix(12)) · \(backup.date.formatted())").font(.caption).foregroundStyle(.secondary) }.tag(backup.id)
                } }.listStyle(.bordered)
            }
            if category != "Remotes" { TextField(category == "Stashes" ? "Restored stash message" : "Restore as name", text: $name) }
            else if remote != nil { Text("Restores remote configuration and available upstream settings. Fetch afterward to refresh remote-tracking references.").font(.caption).foregroundStyle(.secondary) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            ManagementFooter(title: "Restore", disabled: store.isBusy || loading || selected == nil || (category != "Remotes" && (reference == nil || name.isEmpty))) {
                let reference = reference, remote = remote, name = name, category = category
                store.perform("Restoring deleted item…") { repo in
                    if category == "Remotes", let remote { try await repo.restoreRemote(remote) }
                    else if let reference { try await repo.restoreReferenceBackup(reference, name: name) }
                }; dismiss()
            }
        }.padding(24).frame(width: 650, height: 520)
        .task { do { backups = try await store.repository?.referenceBackups() ?? []; remotes = try await store.repository?.removedRemotes() ?? [] } catch { failure = error.localizedDescription }; loading = false }
        .onChange(of: category) { selected = nil; name = "" }
        .onChange(of: selected) { if let reference { name = reference.isStash ? reference.title : reference.fullName.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/tags/", with: "") } }
    }
}
