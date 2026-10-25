import AppKit
import GitCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: RepositoryStore
    @State private var filter = ""
    @State private var outline = SidebarOutline.empty
    var outlineInput: SidebarOutlineInput { SidebarOutlineInput(references: store.snapshot?.references ?? [], remotes: store.snapshot?.remotes ?? [], pinned: store.organization.pinned, archived: store.organization.archived, filter: filter) }
    var selection: Destination {
        switch store.destination {
        case .fileHistory, .comparison: .history
        case .reference(let name) where !name.hasPrefix("refs/"): .history
        default: store.destination
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding<Destination?>(get: { selection }, set: { if let value = $0 { store.navigate(value) } })) {
                Section("Workspace") {
                    Label { HStack { Text("Working Copy"); Spacer(); if !store.changes.isEmpty { Text("\(store.changes.count)").font(.caption).foregroundStyle(.secondary) } } } icon: { Image(systemName: "folder") }.tag(Destination.workingCopy).picoDrop(store, .workingCopy).contextMenu {
                        Button("Discard All Local Changes…") { store.localChange(.discard(store.changes.map(\.path))) }.disabled(store.changes.isEmpty || store.isBusy)
                        Button("Recover Local Changes…") { store.localChange(.recovery) }.disabled(store.isBusy)
                        Divider()
                        Button("Apply Patch…", action: store.choosePatch).disabled(store.isBusy)
                        Button("Save Unstaged Patch…") { store.localChange(.export(.unstaged, [])) }.disabled(store.isBusy)
                        Button("Save Staged Patch…") { store.localChange(.export(.staged, [])) }.disabled(store.isBusy)
                    }
                    Label("History", systemImage: "clock.arrow.circlepath").tag(Destination.history)
                    Label("Stashes", systemImage: "list.clipboard").tag(Destination.stashes).picoDrop(store, .stashes)
                    Label("Pull Requests", systemImage: "arrow.triangle.pull").foregroundStyle(.tertiary).disabled(true).help("Hosted-account integration is not available yet")
                    Label("Branches Review", systemImage: "arrow.left.arrow.right.circle").tag(Destination.branchesReview)
                    Label("Reflog", systemImage: "list.bullet.rectangle").tag(Destination.reflog)
                    Label("Settings", systemImage: "gearshape").tag(Destination.repositorySettings)
                }
                Section {
                    ForEach(outline.pinned) { ref in
                        referenceRow(ref, title: ref.name, icon: "pin")
                    }
                    OutlineGroup(outline.branches, children: \.children) { node in
                        if let ref = node.reference { referenceRow(ref, title: node.name, icon: "arrow.triangle.branch") }
                        else { Label(node.name, systemImage: "folder") }
                    }
                } header: { Text("Branches").frame(maxWidth: .infinity, alignment: .leading).picoDrop(store, .branches) }
                if !outline.archived.isEmpty {
                    Section("Archived Branches") {
                        OutlineGroup(outline.archived, children: \.children) { node in
                            if let ref = node.reference { referenceRow(ref, title: node.name, icon: "archivebox") }
                            else { Label(node.name, systemImage: "folder") }
                        }
                    }
                }
                Section {
                    OutlineGroup(outline.tags, children: \.children) { node in
                        if let ref = node.reference { referenceRow(ref, title: node.name, icon: "tag") }
                        else { Label(node.name, systemImage: "folder") }
                    }
                } header: { Text("Tags").frame(maxWidth: .infinity, alignment: .leading).picoDrop(store, .tags) }
                Section("Related Repositories") {
                    Label("Worktrees (\(store.worktrees.count))", systemImage: "folder.badge.gearshape").tag(Destination.worktrees).contextMenu { Button("Add Worktree…") { store.manageWorktree(.create(nil)) } }
                    ForEach(store.worktrees.filter { !$0.isBare }) { entry in
                        Button { store.openWorktree(entry) } label: { Label(entry.name + (entry.locked != nil ? " 🔒" : ""), systemImage: "folder") }.buttonStyle(.plain).padding(.leading, 12).disabled(entry.prunable != nil).contextMenu { WorktreeContextActions(store: store, entry: entry) }
                    }
                    Label("Submodules (\(store.submodules.count))", systemImage: "shippingbox").tag(Destination.submodules).contextMenu { Button("Add Submodule…") { store.manageSubmodule(.add) } }
                    ForEach(store.submodules) { entry in
                        Button { if entry.initialized { store.openSubmodule(entry) } else { store.manageSubmodule(.manage(entry, .initialize)) } } label: { Label(entry.path, systemImage: "shippingbox") }.buttonStyle(.plain).padding(.leading, 12).contextMenu { SubmoduleContextActions(store: store, entry: entry) }
                    }
                }
                Section("Remotes") {
                    ForEach(store.snapshot?.remotes ?? [], id: \.self) { remote in
                        DisclosureGroup {
                            OutlineGroup(outline.remotes[remote] ?? [], children: \.children) { node in
                                if let ref = node.reference { referenceRow(ref, title: node.name, icon: "arrow.triangle.branch") }
                                else { Label(node.name, systemImage: "folder") }
                            }
                        } label: { Label(remote, systemImage: "network").picoDrop(store, .remote(remote)).contextMenu {
                            if let value = store.managedRemotes.first(where: { $0.name == remote }) {
                                Button("Fetch…") { store.manage(.fetch(value)) }
                                Button("Edit Remote…") { store.manage(.editRemote(value)) }
                                Button("Rename Remote…") { store.manage(.renameRemote(value)) }
                                Button("Remove Remote…", role: .destructive) { store.manage(.removeRemote(value)) }
                            }
                        } }
                    }
                }
            }.listStyle(.sidebar).disabled(store.isBusy)
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                TextField("Filter", text: $filter).textFieldStyle(.plain)
                Menu {
                    Button("Create New Branch…") { store.showingBranchSheet = true }
                    Button("Create New Tag…") { store.manage(.createTag("HEAD")) }
                    Button("Add New Remote…") { store.manage(.addRemote) }
                    Button("Add Worktree…") { store.manageWorktree(.create(nil)) }
                    Button("Add Submodule…") { store.manageSubmodule(.add) }
                    Divider()
                    Button("Recover Deleted Items…") { store.manage(.recovery) }
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help("Add branch, tag, remote, worktree or submodule")
                Button { store.navigate(.repositorySettings) } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain).help("Repository settings")
            }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 28)
        }
        .task(id: outlineInput) {
            let input = outlineInput
            let value = await Task.detached(priority: .userInitiated) { SidebarOutline.make(input) }.value
            guard !Task.isCancelled else { return }
            outline = value
        }
    }
    func referenceRow(_ ref: Reference, title: String, icon: String) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if ref.isCurrent { Text("HEAD").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
            }
        } icon: { Image(systemName: icon) }
        .tag(Destination.reference(ref.fullName))
        .picoDrag(store, .reference(ref))
        .picoDrop(store, .reference(ref))
        .contextMenu {
            Button("Preview History") { store.navigate(.reference(ref.fullName)) }
            if ref.isLocal {
                Button(ref.isCurrent ? "Current Branch" : "Check Out “\(ref.name)”") { store.switchBranch(ref) }
                    .disabled(store.checkoutUnavailableReason(ref) != nil)
            }
            Divider()
            Button("Export Files at Revision…") { store.historical(.export, revision: ref.hash) }.disabled(store.isBusy)
            Button("Archive Files as ZIP…") { store.historical(.archive, revision: ref.hash) }.disabled(store.isBusy)
            Divider()
            if ref.isLocal {
                if let kind = store.flowConfiguration?.kind(of: ref.name), kind != .support { Button("Git Flow Finish " + kind.rawValue + "…") { store.manageFlow(.finish(ref.name)) }.disabled(store.isBusy || store.activeFlow != nil) }
                Button("Checkout Branch in New Worktree…") { store.manageWorktree(.create(ref.name)) }.disabled(store.worktrees.contains { $0.branch == ref.fullName })
                Button(store.organization.pinned.contains(ref.fullName) ? "Unpin Branch" : "Pin Branch") { store.organize(ref, pinned: !store.organization.pinned.contains(ref.fullName)) }
                Button("Track Upstream Branch…") { store.manage(.upstream(ref)) }
                Button("Publish / Push Branch…") { store.manage(.publish(ref, nil, nil, false)) }.disabled(store.managedRemotes.isEmpty)
                Button("Force Push with Lease…") { store.manage(.publish(ref, nil, nil, true)) }.disabled(store.managedRemotes.isEmpty)
                Button(store.organization.archived.contains(ref.fullName) ? "Unarchive Branch" : "Archive Branch") { store.organize(ref, archived: !store.organization.archived.contains(ref.fullName)) }
                Button("Rename Branch…") { store.manage(.renameBranch(ref)) }
                Button("Delete Branch…", role: .destructive) { store.manage(.deleteBranch(ref)) }.disabled(ref.isCurrent)
            }
            if ref.isRemote, let remote = store.remoteFor(ref) {
                Button("Check Out as Tracking Branch…") { store.manage(.createBranch(ref.hash, ref.fullName)) }
                Button("Delete Remote Branch…", role: .destructive) { store.manage(.publish(nil, remote.name, "refs/heads/" + String(ref.name.dropFirst(remote.name.count + 1)), false)) }
            }
            if ref.isTag {
                Button("Tag Information…") { store.manage(.inspectTag(ref)) }
                Button("Rename Tag…") { store.manage(.renameTag(ref)) }
                Button("Delete Tag…", role: .destructive) { store.manage(.deleteTag(ref)) }
                Button("Publish Tag…") { store.manage(.publish(ref, nil, nil, false)) }.disabled(store.managedRemotes.isEmpty)
            }
            Divider()
            Button("Create New Branch from Here…") { store.manage(.createBranch(ref.hash, nil)) }
            Button("Create New Tag from Here…") { store.manage(.createTag(ref.hash)) }
            if !ref.isCurrent {
                Button("Merge into HEAD…") { store.integrationRequest = IntegrationRequest(action: .merge, revision: ref.fullName) }
                Button("Rebase HEAD onto This Branch…") { store.integrationRequest = IntegrationRequest(action: .rebase, revision: ref.fullName) }
            }
            Button("Compare with Revision…") { store.navigate(.comparison(ref.fullName)) }
            Button("Copy Name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ref.name, forType: .string) }
        }.help(ref.name + (ref.isCurrent ? " · Current branch" : " · Click to preview history"))
    }
}
