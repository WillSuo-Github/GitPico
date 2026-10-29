import SwiftUI

private struct RepositoryOpeningProgressView: View {
    @State private var visible = false

    var body: some View {
        Group {
            if visible {
                ProgressView("Opening repository…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .task {
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            visible = true
        }
    }
}

struct RepositoryPickerView: View {
    @Bindable var workspace: RepositoryWorkspace
    @Bindable var tab: RepositoryTab
    var showsSidebar = true
    @State private var searchFocused = false
    var store: RepositoryStore { tab.store }
    var entries: [SavedRepository] { workspace.library.matches(query: tab.pickerQuery, filter: tab.pickerFilter) }
    var selection: SavedRepository? { entries.first { $0.id == tab.pickerSelection } }
    var body: some View {
        Group {
            if showsSidebar {
                NavigationSplitView {
                    RepositoryPickerSidebarView(workspace: workspace, tab: tab)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                        .toolbar { ToolbarItem { RepositoryMenu(store: store) } }
                } detail: { content }
            } else { content }
        }
        .disabled(tab.isBusy)
        .overlay {
            if tab.isOpening {
                RepositoryOpeningProgressView()
            } else if store.isBusy {
                ProgressView(store.activity).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .task { if tab.pickerSelection == nil { tab.pickerSelection = entries.first?.id }; searchFocused = true }
        .onChange(of: entries.map(\.id)) { if !entries.contains(where: { $0.id == tab.pickerSelection }) { tab.pickerSelection = entries.first?.id } }
        .onKeyPress(.return) { guard !searchFocused, selection != nil else { return .ignored }; openSelected(); return .handled }
    }
    var filterTitle: String {
        switch tab.pickerFilter {
        case .all: String(localized: "All Repositories")
        case .recent: String(localized: "Recently Opened")
        case .favorites: String(localized: "Favorites")
        case .ungrouped: String(localized: "Ungrouped")
        case .group(let id): workspace.library.breadcrumb(id)
        }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Pico.brand, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .shadow(color: Pico.brandBottom.opacity(0.25), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Repositories").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                ActionCard(title: String(localized: "Open Local"), subtitle: String(localized: "A folder on this Mac"), icon: "folder", action: store.chooseRepository)
                ActionCard(title: String(localized: "Clone"), subtitle: String(localized: "From a remote URL"), icon: "arrow.down.circle") { workspace.prepareCreation(clone: true, from: store) }
                ActionCard(title: String(localized: "New"), subtitle: String(localized: "Start an empty repository"), icon: "plus.square.dashed") { workspace.prepareCreation(clone: false, from: store) }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    SectionCaption("\(filterTitle)")
                    Text("\(entries.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        RepositoryPickerSearchField(text: $tab.pickerQuery, isFocused: $searchFocused, submit: openSelected)
                    }
                    .padding(.horizontal, 10).frame(width: 300, height: 28)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(searchFocused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor), lineWidth: searchFocused ? 1.5 : 0.5))
                    Menu {
                        Button("Manage Library…") { store.showingRepositoryLibrary = true }
                        Button("Repair Repository Pointers…") { store.infrastructure(.repair) }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Library tools")
                }
                List(selection: $tab.pickerSelection) {
                    ForEach(entries) { entry in
                        let isOpen = workspace.tabs.contains(where: { $0.root?.path == entry.path })
                        HStack(spacing: 12) {
                            RepositoryGlyph(name: entry.name, size: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(entry.name).font(.system(size: 13, weight: .semibold))
                                    if entry.favorite { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow) }
                                    if isOpen { Chip(text: String(localized: "Open"), tint: .accentColor) }
                                }
                                Text(Pico.abbreviated(entry.path)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            if let opened = entry.lastOpened { Text(opened.picoRelative).font(.system(size: 11)).foregroundStyle(.tertiary) }
                            Button { open(entry) } label: { Image(systemName: "arrow.right.circle.fill").font(.system(size: 18)).foregroundStyle(.tint).frame(width: 26, height: 26).contentShape(Rectangle()) }
                                .buttonStyle(.plain).help("Open \(entry.name)").accessibilityLabel("Open \(entry.name)")
                        }.padding(.vertical, 7).padding(.horizontal, 4).tag(entry.id).contentShape(Rectangle())
                            .contextMenu {
                                Button("Open") { open(entry) }
                                Button(entry.favorite ? "Remove from Favorites" : "Add to Favorites") { do { try workspace.library.setFavorite([entry.id], !entry.favorite) } catch { store.error = error.localizedDescription } }
                                Button("Locate Repository…") { store.chooseLibraryRepository(relocating: entry.id) }
                            }
                    }.onMove(perform: reorderAction)
                }.listStyle(.inset).scrollContentBackground(.hidden)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
                    .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in if let entry = entries.first(where: { ids.contains($0.id) }) { open(entry) } }
                    .overlay { if entries.isEmpty { EmptyPane(title: tab.pickerQuery.isEmpty ? String(localized: "No repositories here yet") : String(localized: "No matches"), subtitle: tab.pickerQuery.isEmpty ? String(localized: "Open a local repository, clone one, or choose another collection.") : String(localized: "No repository name, path or group matches this search."), icon: tab.pickerQuery.isEmpty ? "tray" : "magnifyingglass") } }
                HStack {
                    Label("Double-click or press Return to open", systemImage: "return").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Open Repository", action: openSelected).buttonStyle(.borderedProminent).disabled(selection == nil)
                }
            }
            if let error = workspace.library.error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Pico.deletion) }
        }.frame(maxWidth: 920, maxHeight: .infinity)
            .padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Extends under the toolbar; NativeRepositoryWindows makes the titlebar transparent while the picker is shown.
            .background {
                LinearGradient(stops: [.init(color: Pico.brandTop.opacity(0.10), location: 0), .init(color: .clear, location: 0.32)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(.container, edges: .top).allowsHitTesting(false)
            }
            .safeAreaPadding(.bottom)
    }
    var summary: String {
        let all = workspace.library.matches(filter: .all).count
        let favorites = workspace.library.matches(filter: .favorites).count
        if all == 0 { return String(localized: "Open a repository to get started.") }
        let saved = String(localized: "\(all) saved repositories")
        return favorites > 0 ? saved + " · " + String(localized: "\(favorites) favorites") : saved
    }

    func openSelected() { if let entry = selection ?? entries.first { open(entry) } }
    func open(_ entry: SavedRepository) { Task { await store.openSavedRepository(entry) } }
    var reorderAction: ((IndexSet, Int) -> Void)? {
        guard tab.pickerFilter == .all else { return nil }
        let visibleIDs = entries.map(\.id)
        return { offsets, destination in
            guard !tab.isBusy, tab.pickerFilter == .all, entries.map(\.id) == visibleIDs else { return }
            do { try workspace.library.reorder(visibleIDs, from: offsets, to: destination) }
            catch { store.error = error.localizedDescription }
        }
    }
}

/// Large, friendly entry point for the three ways to get a repository.
struct ActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(.tint)
                    .frame(width: 38, height: 38).background(Color.accentColor.opacity(hovering ? 0.18 : 0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12).frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 1 : 0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor).opacity(0.6), lineWidth: hovering ? 1 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { value in withAnimation(.easeOut(duration: 0.12)) { hovering = value } }
        .accessibilityLabel("\(title), \(subtitle)")
    }
}
