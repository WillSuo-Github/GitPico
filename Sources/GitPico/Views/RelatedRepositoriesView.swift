import GitCore
import SwiftUI

struct WorktreesView: View {
    @Bindable var store: RepositoryStore
    @State private var selection: Set<String> = []
    var entries: [ManagedWorktree] { store.worktrees.filter { store.search.isEmpty || ($0.path + " " + ($0.branch ?? "")).localizedCaseInsensitiveContains(store.search) } }
    var selected: ManagedWorktree? { entries.first { selection.contains($0.id) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Worktrees").font(.headline); Text("\(store.worktrees.count)").foregroundStyle(.secondary); Spacer(); Menu("Selected (\(selection.count))") {
                Button("Manage Selected Worktrees…") { store.relatedAdministration(.worktrees(store.worktrees.filter { selection.contains($0.id) })) }.disabled(selection.isEmpty)
                Button("Select All") { selection = Set(entries.map(\.id)) }
            }; Button("Management Backups…") { store.relatedAdministration(.backups) }; Button("Add Worktree…") { store.manageWorktree(.create(nil)) }.disabled(store.snapshot?.hasHEAD != true || store.isBusy) }.padding(14)
            HStack {
                Button("Move Main Repository…") { store.infrastructure(.move) }
                Button("Repair Pointers…") { store.infrastructure(.repair) }
                Button("Migration / Repair History…") { store.infrastructure(.history) }
                Spacer()
            }.font(.caption).padding(.horizontal, 14).padding(.bottom, 10)
            Divider()
            HSplitView {
                List(entries, selection: $selection) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Image(systemName: "folder.badge.gearshape"); Text(entry.name).fontWeight(.medium); Spacer(); if entry.isMain { Text("Main").font(.caption).foregroundStyle(.secondary) }; if entry.locked != nil { Image(systemName: "lock.fill").foregroundStyle(.secondary) } }
                        Text(entry.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? (entry.isBare ? "Bare repository" : "Detached HEAD")).font(.caption)
                        Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.padding(.vertical, 5).tag(entry.id).contentShape(Rectangle()).onTapGesture(count: 2) { store.openWorktree(entry) }.contextMenu { if selection.count > 1 { Button("Manage Selected Worktrees…") { store.relatedAdministration(.worktrees(store.worktrees.filter { selection.contains($0.id) })) }; Divider() }; WorktreeContextActions(store: store, entry: entry) }
                }.listStyle(.inset).frame(minWidth: 320)
                ScrollView {
                    if let entry = selected {
                        VStack(alignment: .leading, spacing: 18) {
                            Label(entry.name, systemImage: "folder.badge.gearshape").font(.title2.bold())
                            relatedField("Location", entry.path)
                            relatedField("Branch", entry.branch ?? "Detached HEAD")
                            relatedField("HEAD", entry.head ?? "Unborn / bare")
                            if let lock = entry.locked { relatedField("Locked", lock.isEmpty ? "Locked without a reason" : lock) }
                            if let reason = entry.prunable { Label("Unavailable: " + reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                            if store.snapshot?.root.path == entry.path { Text("This is the current working tree.").foregroundStyle(.secondary) }
                            Button("Open Worktree") { store.openWorktree(entry) }.disabled(entry.prunable != nil || entry.isBare)
                            Menu("Manage Worktree") { WorktreeContextActions(store: store, entry: entry) }
                            Text("Worktrees share Git history and branches, with a separate index and working directory. Removing a clean linked worktree keeps its branch, repository data and a restorable directory backup.").font(.caption).foregroundStyle(.secondary)
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    } else { ContentUnavailableView("Select a worktree", systemImage: "folder.badge.gearshape").padding(30) }
                }.frame(minWidth: 340)
            }
            if let error = store.worktreeError { Text(error).foregroundStyle(.red).padding(12) }
        }.disabled(store.isBusy).onChange(of: entries.map(\.id), initial: true) { selection.formIntersection(entries.map(\.id)); if selection.isEmpty { selection = Set(entries.prefix(1).map(\.id)) } }
    }
}

struct WorktreeContextActions: View {
    var store: RepositoryStore
    let entry: ManagedWorktree
    var body: some View {
        Button("Open Worktree") { store.openWorktree(entry) }.disabled(entry.prunable != nil || entry.isBare)
        if !entry.isMain {
            Button(entry.locked == nil ? "Lock Worktree…" : "Unlock Worktree…") { store.manageWorktree(entry.locked == nil ? .lock(entry) : .unlock(entry)) }
            Button("Move Worktree…") { store.manageWorktree(.move(entry)) }.disabled(entry.locked != nil || entry.prunable != nil || store.snapshot?.root.path == entry.path)
            Button("Repair Relocated Worktree…") { store.manageWorktree(.repair(entry)) }
            Divider()
            Button("Force Remove (Back Up First)…", role: .destructive) { store.relatedAdministration(.worktrees([entry]), initialWorktreeOperation: entry.locked == nil ? .forceRemove : .forceUnlockRemove) }.disabled(store.snapshot?.root.path == entry.path)
            Button("Remove Worktree…", role: .destructive) { store.manageWorktree(.remove(entry)) }.disabled(entry.locked != nil || store.snapshot?.root.path == entry.path)
        }
    }
}

struct SubmodulesView: View {
    @Bindable var store: RepositoryStore
    @State private var selection: Set<String> = []
    var entries: [ManagedSubmodule] { store.submodules.filter { store.search.isEmpty || ($0.path + " " + $0.name + " " + $0.url).localizedCaseInsensitiveContains(store.search) } }
    var selected: ManagedSubmodule? { entries.first { selection.contains($0.id) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Submodules").font(.headline); Text("\(store.submodules.count)").foregroundStyle(.secondary); Spacer(); Menu("Selected (\(selection.count))") {
                Button("Manage Selected Submodules…") { store.relatedAdministration(.submodules(store.submodules.filter { selection.contains($0.id) })) }.disabled(selection.isEmpty)
                Button("Select All") { selection = Set(entries.map(\.id)) }
            }; Button("Management Backups…") { store.relatedAdministration(.backups) }; Button("Add Submodule…") { store.manageSubmodule(.add) } }.padding(14)
            Divider()
            HSplitView {
                List(entries, selection: $selection) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(entry.path, systemImage: "shippingbox").fontWeight(.medium)
                        Text(entry.status).font(.caption).foregroundStyle(entry.dirty || entry.diagnostic != nil || entry.conflicted ? Color.orange : Color.secondary)
                        Text(entry.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.padding(.vertical, 5).tag(entry.id).contentShape(Rectangle()).onTapGesture(count: 2) { if entry.initialized { store.openSubmodule(entry) } else { store.manageSubmodule(.manage(entry, .initialize)) } }.contextMenu { if selection.count > 1 { Button("Manage Selected Submodules…") { store.relatedAdministration(.submodules(store.submodules.filter { selection.contains($0.id) })) }; Divider() }; SubmoduleContextActions(store: store, entry: entry) }
                }.listStyle(.inset).frame(minWidth: 320)
                ScrollView {
                    if let entry = selected {
                        VStack(alignment: .leading, spacing: 18) {
                            Label(entry.path, systemImage: "shippingbox").font(.title2.bold())
                            relatedField("Status", entry.status)
                            relatedField("Name", entry.name)
                            relatedField("URL", entry.url)
                            if let url = entry.configuredURL, url != entry.url { relatedField("Local URL", url) }
                            relatedField("Parent records", entry.recordedHash ?? "No stage-zero gitlink")
                            relatedField("Checked out", entry.head ?? "Not initialized")
                            if let branch = entry.branch { relatedField("Tracking branch", branch) }
                            if let directory = entry.gitDirectory { relatedField("Git storage", directory) }
                            HStack {
                                Button(entry.initialized ? "Open Submodule" : "Initialize…") { if entry.initialized { store.openSubmodule(entry) } else { store.manageSubmodule(.manage(entry, .initialize)) } }
                                Menu("Manage Submodule") { SubmoduleContextActions(store: store, entry: entry) }
                            }
                            Text("Updates check out the revision recorded by the parent. After choosing another revision, stage the submodule in the parent's Working Copy to record its gitlink. No parent commit is created automatically.").font(.caption).foregroundStyle(.secondary)
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    } else { ContentUnavailableView("Select a submodule", systemImage: "shippingbox", description: Text("Add a Git repository inside this working tree.")).padding(30) }
                }.frame(minWidth: 340)
            }
            if let error = store.submoduleError { Text(error).foregroundStyle(.red).padding(12) }
        }.disabled(store.isBusy).onChange(of: entries.map(\.id), initial: true) { selection.formIntersection(entries.map(\.id)); if selection.isEmpty { selection = Set(entries.prefix(1).map(\.id)) } }
    }
}
struct SubmoduleContextActions: View {
    var store: RepositoryStore
    let entry: ManagedSubmodule
    var body: some View {
        Button("Open Submodule") { store.openSubmodule(entry) }.disabled(!entry.initialized || entry.diagnostic != nil)
        ForEach(SubmoduleOperation.allCases.filter { $0 != .remove && $0 != .deinitialize }, id: \.self) { operation in
            Button(operation.rawValue + "…") { store.manageSubmodule(.manage(entry, operation)) }.disabled((operation == .fetch || operation == .checkout) && !entry.initialized)
        }
        Divider()
        Button("Deinitialize…") { store.manageSubmodule(.manage(entry, .deinitialize)) }.disabled(!entry.initialized)
        Button("Remove Submodule…", role: .destructive) { store.manageSubmodule(.manage(entry, .remove)) }
    }
}

@ViewBuilder func relatedField(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).textSelection(.enabled).lineLimit(4).truncationMode(.middle) }
}
