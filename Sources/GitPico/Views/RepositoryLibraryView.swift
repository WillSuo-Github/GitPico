import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension RepositoryLibraryDrop: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "com.willsuo.gitpico.repository-library-item"))
    }
}
private struct LibraryEditor: Identifiable {
    enum Kind { case create(UUID?), renameRepository(UUID), renameGroup(UUID) }
    let id = UUID()
    let title: String
    let value: String
    let kind: Kind
}

struct RepositoryLibraryView: View {
    @Bindable var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var filter = RepositoryLibraryFilter.all
    @State private var query = ""
    @State private var selection: Set<UUID> = []
    @State private var editor: LibraryEditor?
    @State private var failure: String?
    var library: RepositoryLibrary { store.library }
    var entries: [SavedRepository] { library.matches(query: query, filter: filter) }
    var current: SavedRepository? { entries.first { selection.contains($0.id) } }
    var currentGroup: UUID? { if case .group(let id) = filter { id } else { nil } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Repositories").font(.title2.bold())
                Spacer()
                TextField("Search name, path or group", text: $query).textFieldStyle(.roundedBorder).frame(width: 290)
                Button { library.reload(); failure = nil } label: { Image(systemName: "arrow.clockwise") }.help("Reload repository library")
            }.padding(16)
            Divider()
            HStack(spacing: 0) {
                List(selection: Binding<RepositoryLibraryFilter?>(get: { filter }, set: { if let value = $0 { filter = value } })) {
                    Label("All Repositories", systemImage: "tray.full").tag(RepositoryLibraryFilter.all).dropDestination(for: RepositoryLibraryDrop.self, action: { (tokens: [RepositoryLibraryDrop], _: CGPoint) -> Bool in library.acceptDrop(tokens, to: nil) })
                    Label("Favorites", systemImage: "star").tag(RepositoryLibraryFilter.favorites)
                    Label("Recent", systemImage: "clock").tag(RepositoryLibraryFilter.recent)
                    Label("Ungrouped", systemImage: "folder").tag(RepositoryLibraryFilter.ungrouped).dropDestination(for: RepositoryLibraryDrop.self, action: { (tokens: [RepositoryLibraryDrop], _: CGPoint) -> Bool in library.acceptDrop(tokens, to: nil) })
                    Section("Groups") {
                        ForEach(library.orderedGroups) { group in
                            Label(library.breadcrumb(group.id), systemImage: "folder").lineLimit(2).tag(RepositoryLibraryFilter.group(group.id))
                                .dropDestination(for: RepositoryLibraryDrop.self, action: { (tokens: [RepositoryLibraryDrop], _: CGPoint) -> Bool in library.acceptDrop(tokens, to: group.id) })
                                .contextMenu { groupMenu(group) }
                        }
                    }
                }.listStyle(.sidebar).frame(width: 240)
                Divider()
                VStack(spacing: 0) {
                    List(entries, selection: $selection) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.favorite ? "star.fill" : "folder").foregroundStyle(entry.favorite ? Color.yellow : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name).font(.callout.weight(.medium))
                                Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if entry.path == store.snapshot?.root.path { Text("Open").font(.caption).foregroundStyle(.secondary) }
                            Text(library.breadcrumb(entry.group)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }.padding(.vertical, 4).tag(entry.id).contentShape(Rectangle())
                            .onTapGesture(count: 2) { open(entry) }
                            .contextMenu { repositoryMenu(entry) }
                            .draggable(RepositoryLibraryDrop(session: library.session, repositories: selection.contains(entry.id) ? Array(selection) : [entry.id]))
                            .dropDestination(for: RepositoryLibraryDrop.self, action: { (tokens: [RepositoryLibraryDrop], _: CGPoint) -> Bool in library.acceptDrop(tokens, to: entry.group, before: entry.id) })
                    }.listStyle(.plain)
                        .overlay { if entries.isEmpty { ContentUnavailableView("No repositories", systemImage: "folder", description: Text(query.isEmpty ? "Add a local Git repository to this library." : "No repositories match this search.")) } }
                    if let current {
                        Divider()
                        HStack {
                            Text(current.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer()
                            Button("Locate…") { store.chooseLibraryRepository(relocating: current.id) }.controlSize(.small)
                        }.padding(12)
                    }
                }
            }.frame(height: 420)
            Divider()
            if let error = failure ?? library.error { HStack { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled); Spacer() }.padding([.horizontal, .top], 12) }
            HStack {
                Menu {
                    Button("Add Local Repository…") { store.chooseLibraryRepository() }
                    Button("New Group…") { editor = LibraryEditor(title: "New Group", value: "", kind: .create(currentGroup)) }
                    Divider()
                    Button("Sort Contents by Name") { perform { try library.sortContents(of: currentGroup) } }
                } label: { Label("Add / Organize", systemImage: "plus") }.fixedSize()
                Text("\(entries.count) repositories").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") { if let current { open(current) } }.keyboardShortcut(.defaultAction).disabled(selection.count != 1)
            }.padding(14)
        }.frame(width: 960).disabled(store.isBusy)
            .onChange(of: filter) { selection = [] }
            .onChange(of: entries.map(\.id)) { selection.formIntersection(Set(entries.map(\.id))) }
            .sheet(item: $editor) { item in LibraryNameSheet(title: item.title, initial: item.value) { name in
                switch item.kind {
                case .create(let parent): perform { _ = try library.createGroup(name, parent: parent) }
                case .renameRepository(let id): perform { try library.rename([id], to: name) }
                case .renameGroup(let id): perform { try library.renameGroup(id, name) }
                }
            } }
    }
    @ViewBuilder func repositoryMenu(_ entry: SavedRepository) -> some View {
        let ids = selection.contains(entry.id) ? selection : [entry.id]
        Button("Open") { open(entry) }
        Button(entry.favorite ? "Remove from Favorites" : "Add to Favorites") { perform { try library.setFavorite(ids, !entry.favorite) } }
        Button("Rename…") { editor = LibraryEditor(title: "Rename Repository", value: entry.name, kind: .renameRepository(entry.id)) }
        Menu("Move To") {
            Button("Ungrouped") { perform { try library.move(ids, to: nil) } }
            ForEach(library.orderedGroups) { group in Button(library.breadcrumb(group.id)) { perform { try library.move(ids, to: group.id) } } }
        }
        Button("Move Before Previous") {
            let peers = library.document.repositories.filter { $0.group == entry.group }
            if let index = peers.firstIndex(where: { $0.id == entry.id }), index > 0 { perform { try library.move([entry.id], to: entry.group, before: peers[index - 1].id) } }
        }
        Divider()
        Button("Locate Repository…") { store.chooseLibraryRepository(relocating: entry.id) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
        Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path, forType: .string) }
        Divider()
        Button("Remove from Library") { perform { try library.remove(ids) } }
    }
    @ViewBuilder func groupMenu(_ group: RepositoryGroup) -> some View {
        Button("New Subgroup…") { editor = LibraryEditor(title: "New Group", value: "", kind: .create(group.id)) }
        Button("Rename Group…") { editor = LibraryEditor(title: "Rename Group", value: group.name, kind: .renameGroup(group.id)) }
        Menu("Move Group To") {
            Button("Top Level") { perform { try library.moveGroup(group.id, parent: nil) } }
            ForEach(library.orderedGroups.filter { $0.id != group.id }) { parent in Button(library.breadcrumb(parent.id)) { perform { try library.moveGroup(group.id, parent: parent.id) } } }
        }
        Button("Sort Contents by Name") { perform { try library.sortContents(of: group.id) } }
        Button("Remove Group (Keep Repositories)") { perform { try library.removeGroup(group.id) }; if filter == .group(group.id) { filter = .all } }
    }
    func perform(_ action: () throws -> Void) { do { try action(); failure = nil } catch { failure = error.localizedDescription } }
    func open(_ entry: SavedRepository) { guard !store.isBusy else { return }; dismiss(); Task { await store.openSavedRepository(entry) } }
}

private struct LibraryNameSheet: View {
    let title: String
    let initial: String
    let action: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Save") { action(name); dismiss() }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 420).onAppear { name = initial }
    }
}
