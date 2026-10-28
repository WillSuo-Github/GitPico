import GitCore
import SwiftUI

struct WorktreesView: View {
    @Bindable var store: RepositoryStore
    @State private var selection: Set<String> = []
    var entries: [ManagedWorktree] { store.worktrees.filter { store.search.isEmpty || ($0.path + " " + ($0.branch ?? "")).localizedCaseInsensitiveContains(store.search) } }
    var selected: ManagedWorktree? { entries.first { selection.contains($0.id) } }
    var body: some View {
        VStack(spacing: 0) {
            PaneBar(title: "Worktrees", subtitle: String(localized: "\(store.worktrees.count) checked-out directories sharing this repository"), icon: "folder.badge.gearshape") {
                Menu {
                    Section("Selection") {
                        Button("Manage Selected Worktrees…") { store.relatedAdministration(.worktrees(store.worktrees.filter { selection.contains($0.id) })) }.disabled(selection.isEmpty)
                        Button("Select All") { selection = Set(entries.map(\.id)) }
                    }
                    Section("Maintenance") {
                        Button("Management Backups…") { store.relatedAdministration(.backups) }
                        Button("Move Main Repository…") { store.infrastructure(.move) }
                        Button("Repair Pointers…") { store.infrastructure(.repair) }
                        Button("Migration / Repair History…") { store.infrastructure(.history) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Selection and maintenance")
                Button { store.manageWorktree(.create(nil)) } label: { Label("Add Worktree", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.small).disabled(store.snapshot?.hasHEAD != true || store.isBusy)
            }
            PersistentSplitView(name: "worktrees", width: 340) {
                List(entries, selection: $selection) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.locked != nil ? "lock.fill" : entry.prunable != nil ? "exclamationmark.triangle.fill" : "folder.fill")
                            .font(.system(size: 13)).foregroundStyle(entry.prunable != nil ? Pico.warning : Color.accentColor)
                            .frame(width: 28, height: 28).background((entry.prunable != nil ? Pico.warning : Color.accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(entry.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                if entry.isMain { Chip(text: String(localized: "Main"), tint: .secondary) }
                                if store.snapshot?.root.path == entry.path { Chip(text: String(localized: "Current"), tint: .accentColor) }
                            }
                            Label(entry.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? (entry.isBare ? String(localized: "Bare repository") : String(localized: "Detached HEAD")), systemImage: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(Pico.abbreviated(entry.path)).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }.padding(.vertical, 4).tag(entry.id).contentShape(Rectangle()).onTapGesture(count: 2) { store.openWorktree(entry) }.contextMenu { if selection.count > 1 { Button("Manage Selected Worktrees…") { store.relatedAdministration(.worktrees(store.worktrees.filter { selection.contains($0.id) })) }; Divider() }; WorktreeContextActions(store: store, entry: entry) }
                }.listStyle(.plain)
            } trailing: {
                ScrollView {
                    if let entry = selected {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.badge.gearshape").font(.system(size: 20)).foregroundStyle(.tint).frame(width: 44, height: 44).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name).font(.system(size: 17, weight: .semibold))
                                    Text(store.snapshot?.root.path == entry.path ? "This is the current working tree" : entry.isMain ? "Main working tree" : "Linked worktree").font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu("Manage") { WorktreeContextActions(store: store, entry: entry) }.fixedSize().controlSize(.small)
                                Button("Open") { store.openWorktree(entry) }.buttonStyle(.borderedProminent).controlSize(.small).disabled(entry.prunable != nil || entry.isBare || store.snapshot?.root.path == entry.path)
                            }
                            if let reason = entry.prunable { Label("Unavailable: \(reason)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Pico.warning) }
                            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                                MetadataRow(label: "Location", value: entry.path)
                                MetadataRow(label: "Branch", value: entry.branch?.replacingOccurrences(of: "refs/heads/", with: "") ?? String(localized: "Detached HEAD"))
                                MetadataRow(label: "HEAD", value: entry.head ?? String(localized: "Unborn / bare"), monospaced: true)
                                if let lock = entry.locked { MetadataRow(label: "Locked", value: lock.isEmpty ? String(localized: "Locked without a reason") : lock) }
                            }.card()
                            Label("Worktrees share history and branches but keep a separate index and working directory. Removing a clean linked worktree keeps its branch, repository data and a restorable directory backup.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    } else { EmptyPane(title: String(localized: "Select a worktree"), subtitle: String(localized: "Worktrees let you check out several branches side by side."), icon: "folder.badge.gearshape").padding(.top, 60) }
                }
            }
            if let error = store.worktreeError { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Pico.deletion).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
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
    func needsAttention(_ entry: ManagedSubmodule) -> Bool { entry.dirty || entry.diagnostic != nil || entry.conflicted || !entry.initialized }
    var body: some View {
        VStack(spacing: 0) {
            PaneBar(title: "Submodules", subtitle: store.submodules.isEmpty ? String(localized: "No nested repositories") : String(localized: "\(store.submodules.count) nested repositories"), icon: "shippingbox") {
                Menu {
                    Button("Manage Selected Submodules…") { store.relatedAdministration(.submodules(store.submodules.filter { selection.contains($0.id) })) }.disabled(selection.isEmpty)
                    Button("Select All") { selection = Set(entries.map(\.id)) }
                    Divider()
                    Button("Management Backups…") { store.relatedAdministration(.backups) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Selection and maintenance")
                Button { store.manageSubmodule(.add) } label: { Label("Add Submodule", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.small).disabled(store.isBusy)
            }
            PersistentSplitView(name: "submodules", width: 340) {
                List(entries, selection: $selection) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "shippingbox.fill").font(.system(size: 13)).foregroundStyle(needsAttention(entry) ? Pico.warning : Color.accentColor)
                            .frame(width: 28, height: 28).background((needsAttention(entry) ? Pico.warning : Color.accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.path).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Text(entry.status).font(.system(size: 11, weight: .medium)).foregroundStyle(needsAttention(entry) ? Pico.warning : Pico.addition)
                            Text(entry.url).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }.padding(.vertical, 4).tag(entry.id).contentShape(Rectangle()).onTapGesture(count: 2) { if entry.initialized { store.openSubmodule(entry) } else { store.manageSubmodule(.manage(entry, .initialize)) } }.contextMenu { if selection.count > 1 { Button("Manage Selected Submodules…") { store.relatedAdministration(.submodules(store.submodules.filter { selection.contains($0.id) })) }; Divider() }; SubmoduleContextActions(store: store, entry: entry) }
                }.listStyle(.plain)
            } trailing: {
                ScrollView {
                    if let entry = selected {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 12) {
                                Image(systemName: "shippingbox").font(.system(size: 20)).foregroundStyle(.tint).frame(width: 44, height: 44).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.path).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                    Text(entry.status).font(.system(size: 12, weight: .medium)).foregroundStyle(needsAttention(entry) ? Pico.warning : Pico.addition)
                                }
                                Spacer()
                                Menu("Manage") { SubmoduleContextActions(store: store, entry: entry) }.fixedSize().controlSize(.small)
                                Button(entry.initialized ? "Open" : "Initialize…") { if entry.initialized { store.openSubmodule(entry) } else { store.manageSubmodule(.manage(entry, .initialize)) } }.buttonStyle(.borderedProminent).controlSize(.small)
                            }
                            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                                MetadataRow(label: "Name", value: entry.name)
                                MetadataRow(label: "URL", value: entry.url)
                                if let url = entry.configuredURL, url != entry.url { MetadataRow(label: "Local URL", value: url) }
                                MetadataRow(label: "Recorded", value: entry.recordedHash ?? String(localized: "No stage-zero gitlink"), monospaced: true)
                                MetadataRow(label: "Checked out", value: entry.head ?? String(localized: "Not initialized"), monospaced: true)
                                if let branch = entry.branch { MetadataRow(label: "Tracking", value: branch) }
                                if let directory = entry.gitDirectory { MetadataRow(label: "Git storage", value: directory) }
                            }.card()
                            Label("Updates check out the revision recorded by the parent. After choosing another revision, stage the submodule in the parent's Working Copy to record its gitlink. No parent commit is created automatically.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    } else { EmptyPane(title: store.submodules.isEmpty ? String(localized: "No submodules") : String(localized: "Select a submodule"), subtitle: String(localized: "Submodules embed another Git repository at a pinned revision."), icon: "shippingbox").padding(.top, 60) }
                }
            }
            if let error = store.submoduleError { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Pico.deletion).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
        }.disabled(store.isBusy).onChange(of: entries.map(\.id), initial: true) { selection.formIntersection(entries.map(\.id)); if selection.isEmpty { selection = Set(entries.prefix(1).map(\.id)) } }
    }
}
struct SubmoduleContextActions: View {
    var store: RepositoryStore
    let entry: ManagedSubmodule
    var body: some View {
        Button("Open Submodule") { store.openSubmodule(entry) }.disabled(!entry.initialized || entry.diagnostic != nil)
        ForEach(SubmoduleOperation.allCases.filter { $0 != .remove && $0 != .deinitialize }, id: \.self) { operation in
            Button(operation.actionTitle) { store.manageSubmodule(.manage(entry, operation)) }.disabled((operation == .fetch || operation == .checkout) && !entry.initialized)
        }
        Divider()
        Button("Deinitialize…") { store.manageSubmodule(.manage(entry, .deinitialize)) }.disabled(!entry.initialized)
        Button("Remove Submodule…", role: .destructive) { store.manageSubmodule(.manage(entry, .remove)) }
    }
}

@ViewBuilder func relatedField(_ title: LocalizedStringResource, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).textSelection(.enabled).lineLimit(4).truncationMode(.middle) }
}
