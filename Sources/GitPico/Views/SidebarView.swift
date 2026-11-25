import AppKit
import GitCore
import SwiftUI

struct SidebarView: View {
    @Bindable var store: RepositoryStore
    @Environment(\.repositoryStatusBarInset) private var statusBarInset
    private static let filterBarHeight: CGFloat = 34
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
    @AppStorage("sidebar.archivedExpanded") private var archivedExpanded = true
    @AppStorage("sidebar.tagsExpanded") private var tagsExpanded = true
    @AppStorage("sidebar.remotesExpanded") private var remotesExpanded = true
    @AppStorage("sidebar.relatedExpanded") private var relatedExpanded = true
    @AppStorage("sidebar.toolsExpanded") private var toolsExpanded = true
    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding<Set<Destination>>(get: { selectedDestinations }, set: { values in
                selectedDestinations = values
                // A group selection must not choose an arbitrary branch to preview or activate.
                if values.count == 1, let value = values.first { store.navigate(value) }
            })) {
                Section {
                    SidebarRowLabel(
                        "Working Copy",
                        systemImage: "square.and.pencil",
                        bold: !store.changes.isEmpty
                    ) {
                        if !store.changes.isEmpty {
                            Text(store.changes.count, format: .number)
                                .font(.system(size: 10)).bold()
                                .foregroundStyle(.secondary)
                                .padding(.trailing, 4)
                        }
                    }
                    .tag(Destination.workingCopy).picoDrop(store, .workingCopy)
                    SidebarRowLabel("History", systemImage: "clock.arrow.circlepath").tag(Destination.history)
                    SidebarRowLabel("Stashes", systemImage: "tray.full").badge(store.snapshot?.stashes.count ?? 0).tag(Destination.stashes).picoDrop(store, .stashes)
                } header: { Text("Workspace") }
                Section {
                    if branchesExpanded {
                        ForEach(outline.pinned) { ref in
                            referenceRow(ref, title: ref.name, icon: "pin")
                        }
                        OutlineGroup(outline.branches, children: \.children) { node in
                            if let ref = node.reference { referenceRow(ref, title: node.name, icon: "arrow.triangle.branch") }
                            else { SidebarRowLabel(verbatim: node.name, systemImage: "folder") }
                        }
                    }
                } header: {
                    SidebarSectionHeader(title: "Branches", isExpanded: $branchesExpanded)
                        .picoDrop(store, .branches)
                }
                if !outline.archived.isEmpty {
                    Section {
                        if archivedExpanded {
                            OutlineGroup(outline.archived, children: \.children) { node in
                                if let ref = node.reference { referenceRow(ref, title: node.name, icon: "archivebox") }
                                else { SidebarRowLabel(verbatim: node.name, systemImage: "folder") }
                            }
                        }
                    } header: {
                        SidebarSectionHeader(title: "Archived Branches", isExpanded: $archivedExpanded)
                    }
                }
                Section {
                    if remotesExpanded {
                        ForEach(store.snapshot?.remotes ?? [], id: \.self) { remote in
                            DisclosureGroup {
                                OutlineGroup(outline.remotes[remote] ?? [], children: \.children) { node in
                                    if let ref = node.reference { referenceRow(ref, title: node.name, icon: "arrow.triangle.branch") }
                                    else { SidebarRowLabel(verbatim: node.name, systemImage: "folder") }
                                }
                            } label: {
                                SidebarRowLabel(verbatim: remote, systemImage: "cloud")
                                    .picoDrop(store, .remote(remote))
                                    .contextMenu {
                                        if let value = store.managedRemotes.first(where: { $0.name == remote }) {
                                            Button("Fetch…") { store.manage(.fetch(value)) }
                                            Button("Edit Remote…") { store.manage(.editRemote(value)) }
                                            Button("Rename Remote…") { store.manage(.renameRemote(value)) }
                                            Button("Remove Remote…", role: .destructive) { store.manage(.removeRemote(value)) }
                                        }
                                    }
                            }
                        }
                        if store.snapshot?.remotes.isEmpty != false {
                            Button { store.manage(.addRemote) } label: { SidebarRowLabel("Add Remote…", systemImage: "plus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    SidebarSectionHeader(title: "Remotes", isExpanded: $remotesExpanded)
                }
                Section {
                    if tagsExpanded {
                        OutlineGroup(outline.tags, children: \.children) { node in
                            if let ref = node.reference { referenceRow(ref, title: node.name, icon: "tag") }
                            else { SidebarRowLabel(verbatim: node.name, systemImage: "folder") }
                        }
                        if outline.tags.isEmpty {
                            if filter.isEmpty {
                                Button { store.manage(.createTag("HEAD")) } label: { SidebarRowLabel("New Tag…", systemImage: "plus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(store.snapshot?.hasHEAD != true)
                            } else { Text("No matching tags").foregroundStyle(.tertiary) }
                        }
                    }
                } header: {
                    SidebarSectionHeader(title: "Tags", isExpanded: $tagsExpanded)
                        .picoDrop(store, .tags)
                }
                Section {
                    if relatedExpanded {
                        SidebarRowLabel("Worktrees", systemImage: "folder.badge.gearshape").badge(store.worktrees.filter { !$0.isMain && !$0.isBare }.count).tag(Destination.worktrees)
                        if store.worktrees.count > 1 {
                            ForEach(store.worktrees.filter { !$0.isBare }) { entry in
                                SidebarWorktreeRow(store: store, entry: entry)
                                    .tag(Destination.worktree(entry.path))
                            }
                        }
                        SidebarRowLabel("Submodules", systemImage: "shippingbox").badge(store.submodules.count).tag(Destination.submodules)
                        ForEach(store.submodules) { entry in
                            Button { if entry.initialized { store.openSubmodule(entry) } else { store.manageSubmodule(.manage(entry, .initialize)) } } label: { SidebarRowLabel(verbatim: entry.path, systemImage: "shippingbox") }.buttonStyle(.plain).padding(.leading, 12).contextMenu { SubmoduleContextActions(store: store, entry: entry) }
                        }
                    }
                } header: {
                    SidebarSectionHeader(title: "Related Repositories", isExpanded: $relatedExpanded)
                }
                Section {
                    if toolsExpanded {
                        HostedReviewWebMenu(store: store, usesSidebarRow: true)
                        SidebarRowLabel("Branches Review", systemImage: "arrow.left.arrow.right").tag(Destination.branchesReview)
                        SidebarRowLabel("Reflog", systemImage: "list.bullet.rectangle").tag(Destination.reflog)
                    }
                } header: {
                    SidebarSectionHeader(title: "Tools", isExpanded: $toolsExpanded)
                }
            }.listStyle(.sidebar)
            .contextMenu(forSelectionType: Destination.self) { destinations in
                SidebarSelectionContextActions(store: store, selection: SidebarContextSelection(destinations, references: store.snapshot?.references ?? []), repositoryToken: store.repositoryToken)
            } primaryAction: { selection in
                store.activateSidebarSelection(selection)
            }
            .disabled(store.isBusy)
            .scrollEdgeEffectHidden(true, for: .vertical)
            .safeAreaInset(edge: .top, spacing: 0) {
                SidebarRepositoryHeader(store: store)
                    .background { ScrollBarBackdrop(edge: .top, showsWindowSurface: false) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
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
                }.font(.system(size: 11)).padding(.horizontal, 10).frame(height: Self.filterBarHeight)
                    // Reserve room for the status labels while the list scrolls behind them.
                    .padding(.bottom, statusBarInset)
                    .background { ScrollBarBackdrop(edge: .bottom, coveredBottom: statusBarInset, showsWindowSurface: false) }
            }
        }
        // Keep the sidebar's header margin outside the viewport, below the window toolbar.
        .padding(.top, 6)
        .background { SidebarScrollEdges().allowsHitTesting(false).accessibilityHidden(true) }
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
        let isSelected = selectedDestinations.contains(.reference(ref.fullName))
        return SidebarRowLabel(
            verbatim: title,
            systemImage: icon,
            iconColor: ref.isCurrent && !isSelected ? Color.accentColor : .secondary
        ) {
            if let status = BranchSyncStatus.current(ref, snapshot: store.snapshot) {
                CurrentBranchBadge(status: status, isSelected: isSelected)
            }
        }
        .contentShape(Rectangle())
        .tag(Destination.reference(ref.fullName))
        .itemProvider { store.isBusy ? nil : store.dragProvider(.reference(ref)) }
        .picoDrop(store, .reference(ref))
        .help(ref.name + (ref.isCurrent ? String(localized: " · Current branch") : String(localized: " · Click to preview history")))
    }
}

struct SidebarRowLabel<Trailing: View>: View {
    private let title: Text
    private let icon: String
    private let iconColor: Color
    private let bold: Bool
    @ViewBuilder private var trailing: Trailing

    init(
        _ title: LocalizedStringKey,
        systemImage icon: String,
        iconColor: Color = .secondary,
        bold: Bool = false,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = Text(title)
        self.icon = icon
        self.iconColor = iconColor
        self.bold = bold
        self.trailing = trailing()
    }

    init(
        verbatim title: String,
        systemImage icon: String,
        iconColor: Color = .secondary,
        bold: Bool = false,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = Text(verbatim: title)
        self.icon = icon
        self.iconColor = iconColor
        self.bold = bold
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: 15, alignment: .center)
                .accessibilityHidden(true)
            title
                .bold(bold)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 2)
    }
}

private struct SidebarSectionHeader: View {
    let title: LocalizedStringKey
    @Binding var isExpanded: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(hovering ? .primary : .secondary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .opacity(hovering ? 1 : 0.85)
                    .frame(width: 14, height: 14)
                    .padding(.trailing, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
        .accessibilityAddTraits(.isHeader)
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
            .padding(.horizontal, 10).padding(.bottom, 4)
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
