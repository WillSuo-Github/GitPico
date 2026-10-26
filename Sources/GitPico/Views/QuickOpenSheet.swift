import SwiftUI

struct QuickOpenSheet: View {
    @Bindable var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: UUID?
    @State private var opening = false
    @FocusState private var focused: Bool
    var results: [SavedRepository] { Array(store.library.matches(query: query, ranked: true).prefix(100)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium)).foregroundStyle(.tint)
                TextField("Jump to a repository", text: $query).textFieldStyle(.plain).font(.system(size: 20, weight: .medium)).focused($focused).onSubmit(open)
                Text("⌘⇧O").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
            }.padding(.horizontal, 18).padding(.vertical, 16)
            Divider()
            List(results, selection: $selected) { entry in
                HStack(spacing: 11) {
                    RepositoryGlyph(name: entry.name, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(entry.name).font(.system(size: 13, weight: .semibold))
                            if entry.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                        }
                        Text(Pico.abbreviated(entry.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(store.library.breadcrumb(entry.group)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }.padding(.vertical, 3).tag(entry.id).contentShape(Rectangle()).onTapGesture(count: 2) { selected = entry.id; open() }
            }.listStyle(.plain).frame(height: 310)
                .overlay { if results.isEmpty { ContentUnavailableView("No matching repositories", systemImage: "folder.badge.questionmark", description: Text("Search by saved name, path or group. Add local repositories from Repositories.")) } }
            Divider()
            HStack {
                Label("↑ ↓ to select · Return to open", systemImage: "keyboard").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open", action: open).keyboardShortcut(.defaultAction).disabled(selected == nil || store.isBusy || opening)
            }.padding(12)
            if let error = store.library.error { Text(error).font(.caption).foregroundStyle(.red).padding([.horizontal, .bottom], 12) }
        }.frame(width: 650)
            .task { selected = results.first?.id; focused = true }
            .onChange(of: results.map(\.id)) { if !results.contains(where: { $0.id == selected }) { selected = results.first?.id } }
            .onKeyPress(.downArrow) { selected = RepositoryQuickSelection.move(selected, in: results, offset: 1); return .handled }
            .onKeyPress(.upArrow) { selected = RepositoryQuickSelection.move(selected, in: results, offset: -1); return .handled }
    }
    func open() {
        guard !opening, !store.isBusy, let entry = results.first(where: { $0.id == selected }) else { return }
        opening = true; dismiss()
        Task { await store.openSavedRepository(entry) }
    }
}
