import AppKit
import GitCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: RepositoryStore
    var filter: String { store.sidebarFilter }
    @State private var outline = SidebarOutline.empty
    var outlineInput: SidebarOutlineInput { SidebarOutlineInput(references: store.snapshot?.references ?? [], remotes: store.snapshot?.remotes ?? [], pinned: store.organization.pinned, archived: store.organization.archived, filter: filter) }
    var selection: Destination {
        switch store.destination {
        case .fileHistory, .comparison: .history
        case .reference(let name) where !name.hasPrefix("refs/"): .history
        default: store.destination
        }
    }
    @AppStorage("sidebar.branchesExpanded") private var branchesExpanded = true
    @AppStorage("sidebar.tagsExpanded") private var tagsExpanded = true
    @AppStorage("sidebar.remotesExpanded") private var remotesExpanded = true
    @AppStorage("sidebar.relatedExpanded") private var relatedExpanded = true
    @AppStorage("sidebar.toolsExpanded") private var toolsExpanded = true
    var body: some View {
        VStack(spacing: 0) {
            SidebarRepositoryHeader(store: store)
            List(selection: Binding<Destination?>(get: { selection }, set: { if let value = $0 { store.navigate(value) } })) {
                Section {
                    Label("Working Copy", systemImage: "square.and.pencil").badge(store.changes.count).tag(Destination.workingCopy).picoDrop(store, .workingCopy).contextMenu {
                        Button("Discard All Local Changes…") { store.localChange(.discard(store.changes.map(\.path))) }.disabled(store.changes.isEmpty || store.isBusy)
                        Button("Recover Local Changes…") { store.localChange(.recovery) }.disabled(store.isBusy)
                        Divider()
                        Button("Apply Patch…", action: store.choosePatch).disabled(store.isBusy)
                        Button("Save Unstaged Patch…") { store.localChange(.export(.unstaged, [])) }.disabled(store.isBusy)
                        Button("Save Staged Patch…") { store.localChange(.export(.staged, [])) }.disabled(store.isBusy)
                    }
                    Label("History", systemImage: "clock.arrow.circlepath").tag(Destination.history)
                    Label("Stashes", systemImage: "tray.full").badge(store.snapshot?.stashes.count ?? 0).tag(Destination.stashes).picoDrop(store, .stashes)
                } header: { Text("Workspace") }
                Section(isExpanded: $branchesExpanded) {
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
                Section(isExpanded: $remotesExpanded) {
                    ForEach(store.snapshot?.remotes ?? [], id: \.self) { remote in
                        DisclosureGroup {
                            OutlineGroup(outline.remotes[remote] ?? [], children: \.children) { node in
                                if let ref = node.reference { referenceRow(ref, title: node.name, icon: "arrow.triangle.branch") }
                                else { Label(node.name, systemImage: "folder") }
                            }
                        } label: { Label(remote, systemImage: "cloud").picoDrop(store, .remote(remote)).contextMenu {
                            if let value = store.managedRemotes.first(where: { $0.name == remote }) {
                                Button("Fetch…") { store.manage(.fetch(value)) }
                                Button("Edit Remote…") { store.manage(.editRemote(value)) }
                                Button("Rename Remote…") { store.manage(.renameRemote(value)) }
                                Button("Remove Remote…", role: .destructive) { store.manage(.removeRemote(value)) }
                            }
                        } }
                    }
                    if store.snapshot?.remotes.isEmpty != false {
                        Button { store.manage(.addRemote) } label: { Label("Add Remote…", systemImage: "plus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                } header: { Text("Remotes") }
                Section(isExpanded: $tagsExpanded) {
                    OutlineGroup(outline.tags, children: \.children) { node in
                        if let ref = node.reference { referenceRow(ref, title: node.name, icon: "tag") }
                        else { Label(node.name, systemImage: "folder") }
                    }
                    if outline.tags.isEmpty {
                        if filter.isEmpty {
                            Button { store.manage(.createTag("HEAD")) } label: { Label("New Tag…", systemImage: "plus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(store.snapshot?.hasHEAD != true)
                        } else { Text("No matching tags").foregroundStyle(.tertiary) }
                    }
                } header: { Text("Tags").frame(maxWidth: .infinity, alignment: .leading).picoDrop(store, .tags) }
                Section(isExpanded: $relatedExpanded) {
                    Label("Worktrees", systemImage: "folder.badge.gearshape").badge(store.worktrees.filter { !$0.isMain && !$0.isBare }.count).tag(Destination.worktrees).contextMenu { Button("Add Worktree…") { store.manageWorktree(.create(nil)) } }
                    ForEach(store.worktrees.filter { !$0.isBare && $0.path != store.snapshot?.root.path }) { entry in
                        Button { store.openWorktree(entry) } label: { Label(entry.name, systemImage: entry.locked != nil ? "lock" : "folder") }.buttonStyle(.plain).padding(.leading, 12).disabled(entry.prunable != nil).help("Open " + entry.path).contextMenu { WorktreeContextActions(store: store, entry: entry) }
                    }
                    Label("Submodules", systemImage: "shippingbox").badge(store.submodules.count).tag(Destination.submodules).contextMenu { Button("Add Submodule…") { store.manageSubmodule(.add) } }
                    ForEach(store.submodules) { entry in
                        Button { if entry.initialized { store.openSubmodule(entry) } else { store.manageSubmodule(.manage(entry, .initialize)) } } label: { Label(entry.path, systemImage: "shippingbox") }.buttonStyle(.plain).padding(.leading, 12).contextMenu { SubmoduleContextActions(store: store, entry: entry) }
                    }
                } header: { Text("Related Repositories") }
                Section(isExpanded: $toolsExpanded) {
                    Button { store.showingHostedReviews = true } label: { Label("Pull / Merge Requests", systemImage: "arrow.triangle.pull") }.buttonStyle(.plain)
                    Label("Branches Review", systemImage: "arrow.left.arrow.right").tag(Destination.branchesReview)
                    Label("Reflog", systemImage: "list.bullet.rectangle").tag(Destination.reflog)
                } header: { Text("Tools") }
            }.listStyle(.sidebar).disabled(store.isBusy && !store.isBackgroundFetching)
            Divider()
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField("Filter branches & tags", text: $store.sidebarFilter).textFieldStyle(.plain)
                    if !store.sidebarFilter.isEmpty {
                        Button { store.sidebarFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("Clear filter")
                    }
                }
                .padding(.horizontal, 8).frame(height: 22)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Menu {
                    Button("New Branch…") { store.showingBranchSheet = true }
                    Button("New Tag…") { store.manage(.createTag("HEAD")) }
                    Button("Add Remote…") { store.manage(.addRemote) }
                    Button("Add Worktree…") { store.manageWorktree(.create(nil)) }
                    Button("Add Submodule…") { store.manageSubmodule(.add) }
                    Divider()
                    Button("Recover Deleted Items…") { store.manage(.recovery) }
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Add branch, tag, remote, worktree or submodule")
                Button { store.navigate(.repositorySettings) } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Repository settings (⌘5)")
            }.font(.system(size: 11)).padding(.horizontal, 10).frame(height: 34)
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
                if let status = BranchSyncStatus.current(ref, snapshot: store.snapshot) {
                    CurrentBranchBadge(status: status)
                }
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

/// Identifies the open repository and its HEAD at a glance; clicking switches repositories.
struct SidebarRepositoryHeader: View {
    @Bindable var store: RepositoryStore
    var name: String { store.workspace?.tab(for: store)?.title ?? store.title }
    var body: some View {
        if let snapshot = store.snapshot {
            Button(action: store.showRepositories) {
                HStack(spacing: 10) {
                    RepositoryGlyph(name: name, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        SidebarHeadSummary(branch: snapshot.branch, ahead: snapshot.ahead, behind: snapshot.behind)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Pico.corner, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isBusy || store.isOpeningRepository)
            .help("Switch repository\n" + snapshot.root.path)
            .accessibilityLabel(Text("Repository \(name), branch \(snapshot.branch). Switch repository"))
            .contextMenu {
                Button("Switch Repository…", action: store.showRepositories)
                Button("Repository Settings") { store.navigate(.repositorySettings) }
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([snapshot.root]) }
                Button("Copy Path") { Pico.copy(snapshot.root.path) }
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
        }
    }
}

private struct SidebarHeadSummary: View {
    let branch: String
    let ahead: Int
    let behind: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch").imageScale(.small)
            Text(branch).lineLimit(1).truncationMode(.middle)
            if ahead > 0 { Text("↑\(ahead)").monospacedDigit() }
            if behind > 0 { Text("↓\(behind)").monospacedDigit() }
        }.font(.system(size: 11)).foregroundStyle(.secondary)
    }
}
