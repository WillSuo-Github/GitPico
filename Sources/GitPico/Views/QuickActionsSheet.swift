import GitCore
import SwiftUI

struct QuickActionsSheet: View {
    @Bindable var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var selected: String?
    @State private var items: [QuickActionItem] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var token = UUID()
    @State private var submitted = false
    @State private var queriedCommit: QuickActionItem?
    var results: [QuickActionItem] {
        let extra = queriedCommit.flatMap { commit in items.contains { $0.id == commit.id } ? nil : commit }
        return Array(QuickActionSearch.results(items + (extra.map { [$0] } ?? []), query: query).prefix(150))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Quick Actions: file, branch, commit or action", text: $query).textFieldStyle(.plain).font(.title3).focused($focused).onSubmit(submit); if loading { ProgressView().controlSize(.small) } }.padding(18)
            Divider()
            List(results, selection: $selected) { item in
                HStack(spacing: 12) { Image(systemName: item.icon).foregroundStyle(.secondary).frame(width: 20); VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.callout); Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }; Spacer() }.padding(.vertical, 3).tag(item.id).contentShape(Rectangle()).onTapGesture(count: 2) { selected = item.id; submit() }
            }.listStyle(.plain).frame(height: 360).overlay { if results.isEmpty && !loading { ContentUnavailableView("No matching actions", systemImage: "magnifyingglass") } }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).padding(10) }
            Divider()
            HStack { Button("Refresh Actions") { Task { await load() } }.disabled(loading); Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Run", action: submit).keyboardShortcut(.defaultAction).disabled(selected == nil || store.isBusy || submitted) }.padding(12)
        }.frame(width: 760).task { focused = true; await load() }
            .task(id: query) {
                queriedCommit = nil
                let revision = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (7...64).contains(revision.count), revision.allSatisfy(\.isHexDigit), let repository = store.repository else { return }
                let expected = store.repositoryToken
                do {
                    try await Task.sleep(for: .milliseconds(200))
                    let commit = try await repository.commit(at: revision)
                    guard !Task.isCancelled, expected == store.repositoryToken, !items.contains(where: { $0.id == "commit:" + commit.hash }) else { return }
                    queriedCommit = QuickActionItem(id: "commit:" + commit.hash, title: commit.subject, subtitle: "Commit · " + commit.hash, icon: "clock", target: .commit(commit))
                } catch { }
            }
            .onChange(of: results.map(\.id)) { if !results.contains(where: { $0.id == selected }) { selected = results.first?.id } }
            .onKeyPress(.downArrow) { selected = QuickActionSearch.move(selected, in: results, offset: 1); return .handled }
            .onKeyPress(.upArrow) { selected = QuickActionSearch.move(selected, in: results, offset: -1); return .handled }
    }
    func load() async {
        loading = true; failure = nil; token = store.repositoryToken
        let expected = token
        do {
            let files = try await store.repository?.workingFiles(includeIgnored: store.showIgnoredFiles) ?? []
            guard expected == store.repositoryToken, !Task.isCancelled else { return }
            items = store.quickActionItems(files: files); selected = results.first?.id
        } catch { failure = error.localizedDescription; items = store.quickActionItems(files: []) }
        loading = false
    }
    func submit() {
        guard !submitted, !store.isBusy, let item = results.first(where: { $0.id == selected }) else { return }
        submitted = true; dismiss()
        // Let the current sheet dismiss before opening a reviewed operation sheet.
        Task { try? await Task.sleep(for: .milliseconds(180)); store.runQuickAction(item, repositoryToken: token) }
    }
}
