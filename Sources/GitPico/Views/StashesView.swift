import GitCore
import SwiftUI

struct StashesView: View {
    @Bindable var store: RepositoryStore
    var stashes: [Stash] { (store.snapshot?.stashes ?? []).filter { store.search.isEmpty || $0.subject.localizedCaseInsensitiveContains(store.search) } }
    var body: some View {
        PersistentSplitView(name: "stashes", width: 320) {
            VStack(spacing: 0) {
                HStack {
                    Text("Stashes").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(store.snapshot?.stashes.count ?? 0)").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        Button("Save Stash…") { store.stashAction(.save([], false)) }.disabled(store.changes.isEmpty)
                        Button("Create Snapshot…") { store.stashAction(.save([], true)) }.disabled(store.changes.isEmpty)
                        Button("Delete All Stashes…") { store.stashAction(.clear(store.snapshot?.stashes ?? [])) }.disabled(store.snapshot?.stashes.isEmpty != false)
                        Divider()
                        Button("Recover Deleted Items…") { store.manage(.recovery) }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                }.padding(.horizontal, 12).frame(height: 40).background(.bar)
                Divider()
                List(selection: Binding(get: { store.selectedStash?.id }, set: { id in if let stash = stashes.first(where: { $0.id == id }) { store.selectStash(stash) } })) {
                    ForEach(stashes) { stash in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(displaySubject(stash)).font(.system(size: 12, weight: .medium)).lineLimit(2); Spacer(minLength: 4); Text(stash.date, format: .dateTime.month(.twoDigits).day(.twoDigits).year(.twoDigits)).font(.system(size: 10)).foregroundStyle(.secondary) }
                            Text("\(stash.name) · \(stash.hash.prefix(8))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }.padding(.vertical, 8).contentShape(Rectangle()).onTapGesture { store.selectStash(stash) }.tag(stash.id).picoDrag(store, .stash(stash))
                        .contextMenu {
                            Button("Apply Stash…") { store.stashAction(.apply(stash)) }
                            Button("Rename Stash…") { store.stashAction(.rename(stash)) }
                            Button("Create Branch from Stash…") { store.stashAction(.branch(stash)) }
                            Divider()
                            Button("Delete Stash…", role: .destructive) { store.stashAction(.delete(stash)) }
                        }
                    }
                }.listStyle(.plain)
                .overlay { if stashes.isEmpty { EmptyPane(title: "No stashes", subtitle: store.search.isEmpty ? "Save local work with Save Stash, or create a snapshot." : "No matching stash messages.", icon: "archivebox") } }
            }
        } trailing: {
            if let stash = store.selectedStash, let repository = store.repository { StashDetailView(store: store, repository: repository, stash: stash).id(stash.id) }
            else { EmptyPane(title: "No stash selected", subtitle: "Select a stash to inspect its changes.", icon: "archivebox") }
        }
        .onAppear { selectFirst() }
        .onChange(of: store.snapshot?.stashes) { selectFirst() }
        .disabled(store.isBusy)
    }
    private func selectFirst() { if store.selectedStash == nil, let first = stashes.first { store.selectStash(first) } }
    private func displaySubject(_ stash: Stash) -> String {
        guard stash.subject.hasPrefix("On "), let colon = stash.subject.range(of: ": ") else { return stash.subject }
        return String(stash.subject[colon.upperBound...])
    }
}

struct StashDetailView: View {
    let store: RepositoryStore
    let repository: GitRepository
    let stash: Stash
    @State private var detail: StashDetail?
    @State private var failure: String?
    @State private var expanded: Set<String> = []
    @State private var selected: Set<String> = []
    @State private var metadataExpanded = true
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(stash.hash.prefix(8)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                DiffLayoutPicker()
                Button("Apply…") { store.stashAction(.apply(stash)) }.controlSize(.small)
                Button("Delete…", role: .destructive) { store.stashAction(.delete(stash)) }.controlSize(.small)
                Menu("More") {
                    Button("Rename Stash…") { store.stashAction(.rename(stash)) }
                    Button("Create Branch from Stash…") { store.stashAction(.branch(stash)) }
                    Button("Recover Deleted Items…") { store.manage(.recovery) }
                }.menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 14).frame(height: 40).background(.bar)
            Divider()
            if let failure { InspectionErrorView(message: failure) }
            else if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("\(detail.commit.author) <\(detail.commit.email)>").font(.system(size: 12))
                                if metadataExpanded {
                                    Text(detail.commit.date.formatted(date: .long, time: .complete)).foregroundStyle(.secondary)
                                    Text("Based on \(detail.base.prefix(12))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                    Text(stash.hash).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }.font(.system(size: 11))
                            Spacer()
                            Text(detail.commit.initials).font(.system(size: 28, weight: .light)).foregroundStyle(.secondary).frame(width: 70, height: 70).background(.quaternary, in: Circle())
                            Button { metadataExpanded.toggle() } label: { Image(systemName: metadataExpanded ? "chevron.down" : "chevron.left") }.buttonStyle(.plain).help("Show or hide stash metadata")
                        }.padding(16)
                        Divider().padding(.horizontal, 14)
                        Text(stash.subject).font(.system(size: 12)).textSelection(.enabled).padding(16)
                        HStack {
                            Button(expanded.count == detail.files.count ? "Collapse All" : "Expand All") { expanded = expanded.count == detail.files.count ? [] : Set(detail.files.map(\.path)) }.buttonStyle(.plain)
                            Button("Apply Selected (\(selected.count))…") { store.stashAction(.files(stash, selected.sorted())) }.disabled(selected.isEmpty).controlSize(.small)
                            if !selected.isEmpty { Text("Drag Selected Files").foregroundStyle(.secondary).picoDrag(store, .stashFiles(stash, selected.sorted())).help("Drag to Working Copy to apply selected files") }
                            Spacer()
                            Text("\(detail.files.count) changed files · +\(detail.statistics.values.reduce(0) { $0 + $1.additions }) −\(detail.statistics.values.reduce(0) { $0 + $1.deletions })").foregroundStyle(.secondary)
                        }.font(.system(size: 10)).padding(.horizontal, 14).padding(.bottom, 12)
                        ForEach(detail.files) { file in
                            StashFileDisclosure(store: store, repository: repository, stash: stash, file: file, statistics: detail.statistics[file.path], expanded: Binding(get: { expanded.contains(file.path) }, set: { if $0 { expanded.insert(file.path) } else { expanded.remove(file.path) } }), selected: Binding(get: { selected.contains(file.path) }, set: { if $0 { selected.insert(file.path) } else { selected.remove(file.path) } }))
                        }
                    }
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task { do { detail = try await repository.stashDetail(stash) } catch { failure = error.localizedDescription } }
    }
}
