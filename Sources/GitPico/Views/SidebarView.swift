import AppKit
import GitCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: RepositoryStore
    @State private var selectedDestinations: Set<Destination> = []
    var filter: String { store.sidebarFilter }
    @State private var outline = SidebarOutline.empty
    var outlineInput: SidebarOutlineInput { SidebarOutlineInput(references: store.snapshot?.references ?? [], remotes: store.snapshot?.remotes ?? [], pinned: store.organization.pinned, archived: store.organization.archived, filter: filter) }
    var selection: Destination {
        switch store.destination {
        case .worktrees, .worktree:
            if store.selectedWorktreePaths.count == 1, let path = store.selectedWorktreePaths.first { return .worktree(path) }
            return .worktrees
        case .fileHistory, .comparison: return .history
        case .reference(let name) where !name.hasPrefix("refs/"): return .history
        default: return store.destination
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
            List(selection: Binding<Set<Destination>>(get: { selectedDestinations }, set: { values in
                selectedDestinations = values
                // A group selection must not choose an arbitrary branch to preview or activate.
                if values.count == 1, let value = values.first { store.navigate(value) }
            })) {
                Section {
                    Label {
                        HStack {
                            Text("Working Copy").bold(!store.changes.isEmpty)
                            Spacer(minLength: 0)
                            if !store.changes.isEmpty {
                                Text(store.changes.count, format: .number)
                                    .font(.system(size: 10)).bold()
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing, 4)
                            }
                        }
                    } icon: {
                        Image(systemName: "square.and.pencil")
                    }
                    .tag(Destination.workingCopy).picoDrop(store, .workingCopy)
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
                    Label("Worktrees", systemImage: "folder.badge.gearshape").badge(store.worktrees.filter { !$0.isMain && !$0.isBare }.count).tag(Destination.worktrees)
                    if store.worktrees.count > 1 {
                        ForEach(store.worktrees.filter { !$0.isBare }) { entry in
                            SidebarWorktreeRow(store: store, entry: entry)
                                .tag(Destination.worktree(entry.path))
                        }
                    }
                    Label("Submodules", systemImage: "shippingbox").badge(store.submodules.count).tag(Destination.submodules)
                    ForEach(store.submodules) { entry in
                        Button { if entry.initialized { store.openSubmodule(entry) } else { store.manageSubmodule(.manage(entry, .initialize)) } } label: { Label(entry.path, systemImage: "shippingbox") }.buttonStyle(.plain).padding(.leading, 12).contextMenu { SubmoduleContextActions(store: store, entry: entry) }
                    }
                } header: { Text("Related Repositories") }
                Section(isExpanded: $toolsExpanded) {
                    HostedReviewWebMenu(store: store)
                    Label("Branches Review", systemImage: "arrow.left.arrow.right").tag(Destination.branchesReview)
                    Label("Reflog", systemImage: "list.bullet.rectangle").tag(Destination.reflog)
                } header: { Text("Tools") }
            }.listStyle(.sidebar)
            .contextMenu(forSelectionType: Destination.self) { destinations in
                SidebarSelectionContextActions(store: store, selection: SidebarContextSelection(destinations, references: store.snapshot?.references ?? []), repositoryToken: store.repositoryToken)
            } primaryAction: { selection in
                store.activateSidebarSelection(selection)
            }
            .disabled(store.isBusy && !store.isFetching)
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
        .onChange(of: selection, initial: true) { _, value in
            selectedDestinations = [value]
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(Destination.reference(ref.fullName))
        .itemProvider { store.isBusy ? nil : store.dragProvider(.reference(ref)) }
        .picoDrop(store, .reference(ref))
        .help(ref.name + (ref.isCurrent ? String(localized: " · Current branch") : String(localized: " · Click to preview history")))
    }
}

/// Identifies the open repository and its HEAD at a glance; clicking switches repositories.
struct SidebarRepositoryHeader: View {
    @Bindable var store: RepositoryStore
    var name: String { store.repositoryDisplayName }
    var accessibilityContext: String {
        let path = store.snapshot?.root.path ?? ""
        guard store.isLinkedWorktree, let entry = store.currentWorktree else { return path }
        return [String(localized: "Worktree"), store.worktreeTitle(entry), path].joined(separator: " · ")
    }
    var body: some View {
        if let snapshot = store.snapshot {
            Button(action: store.showRepositories) {
                HStack(spacing: 10) {
                    RepositoryGlyph(name: name, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            if store.isLinkedWorktree { Chip(text: String(localized: "Worktree"), tint: .accentColor) }
                        }
                        SidebarHeadSummary(branch: snapshot.branch, ahead: snapshot.ahead, behind: snapshot.behind,
                                           worktreeName: store.isLinkedWorktree ? store.currentWorktree.map { store.worktreeTitle($0) } : nil)
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
            .help("Switch repository\n\(snapshot.root.path)")
            .accessibilityLabel(Text("Repository \(name), branch \(snapshot.branch). Switch repository"))
            .accessibilityValue(accessibilityContext)
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
    var worktreeName: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let worktreeName, worktreeName != branch {
                Text(worktreeName).lineLimit(1).truncationMode(.middle)
                Text("·")
            }
            Image(systemName: "arrow.triangle.branch").imageScale(.small)
            Text(branch).lineLimit(1).truncationMode(.middle)
            if ahead > 0 { Text("↑\(ahead)").monospacedDigit() }
            if behind > 0 { Text("↓\(behind)").monospacedDigit() }
        }.font(.system(size: 11)).foregroundStyle(.secondary)
    }
}
