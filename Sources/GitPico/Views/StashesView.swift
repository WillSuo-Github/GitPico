import GitCore
import SwiftUI

struct StashesView: View {
    @Bindable var store: RepositoryStore
    var stashes: [Stash] { (store.snapshot?.stashes ?? []).filter { store.search.isEmpty || $0.subject.localizedCaseInsensitiveContains(store.search) } }
    var body: some View {
        PersistentSplitView(name: "stashes", width: 320) {
            VStack(spacing: 0) {
                PaneBar(title: "Stashes", subtitle: stashes.isEmpty ? String(localized: "Nothing saved") : String(localized: "\(store.snapshot?.stashes.count ?? 0) saved"), icon: "tray.full") {
                    Button { store.stashAction(.save([], false)) } label: { Label("Save Stash", systemImage: "plus") }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(store.changes.isEmpty).help("Save local changes to a new stash")
                    Menu {
                        Button("Save Stash…") { store.stashAction(.save([], false)) }.disabled(store.changes.isEmpty)
                        Button("Create Snapshot…") { store.stashAction(.save([], true)) }.disabled(store.changes.isEmpty)
                        Divider()
                        Button("Recover Deleted Items…") { store.manage(.recovery) }
                        Button("Delete All Stashes…", role: .destructive) { store.stashAction(.clear(store.snapshot?.stashes ?? [])) }.disabled(store.snapshot?.stashes.isEmpty != false)
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                List(selection: Binding(get: { store.selectedStash?.id }, set: { id in if let stash = stashes.first(where: { $0.id == id }) { store.selectStash(stash) } })) {
                    ForEach(stashes) { stash in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "tray.full").font(.system(size: 13)).foregroundStyle(.tint).frame(width: 28, height: 28)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(displaySubject(stash)).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
                                HStack(spacing: 5) {
                                    if let branch = stashBranch(stash) { Text("on \(branch)").lineLimit(1) ; Text("·") }
                                    Text(stash.date.picoRelative)
                                    Spacer(minLength: 0)
                                    Text(stash.name).font(.system(size: 10, design: .monospaced))
                                }.font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6).contentShape(Rectangle()).onTapGesture { store.selectStash(stash) }.tag(stash.id).picoDrag(store, .stash(stash))
                        .contextMenu {
                            Button("Apply Stash…") { store.stashAction(.apply(stash)) }
                            Button("Rename Stash…") { store.stashAction(.rename(stash)) }
                            Button("Create Branch from Stash…") { store.stashAction(.branch(stash)) }
                            Divider()
                            Button("Delete Stash…", role: .destructive) { store.stashAction(.delete(stash)) }
                        }
                    }
                }.listStyle(.plain)
                .overlay { if stashes.isEmpty { EmptyPane(title: store.search.isEmpty ? String(localized: "No stashes") : String(localized: "No matching stashes"), subtitle: store.search.isEmpty ? String(localized: "Stash shelves local changes so you can switch tasks and bring them back later.") : String(localized: "No stash message matches this search."), icon: "tray") } }
            }
        } trailing: {
            if let stash = store.selectedStash, let repository = store.repository { StashDetailView(store: store, repository: repository, stash: stash).id(stash.id) }
            else { EmptyPane(title: String(localized: "Select a stash"), subtitle: String(localized: "Review its files, then apply all of it, single files, chunks or lines."), icon: "tray.full") }
        }
        .onAppear { selectFirst() }
        .onChange(of: store.snapshot?.stashes) { selectFirst() }
        .disabled(store.isBusy)
    }
    private func selectFirst() { if store.selectedStash == nil, let first = stashes.first { store.selectStash(first) } }
    private func stashBranch(_ stash: Stash) -> String? {
        for prefix in ["On ", "WIP on "] where stash.subject.hasPrefix(prefix) {
            if let colon = stash.subject.range(of: ":") { return String(stash.subject[stash.subject.index(stash.subject.startIndex, offsetBy: prefix.count)..<colon.lowerBound]) }
        }
        return nil
    }
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
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HashChip(hash: stash.hash)
                Chip(text: stash.name, icon: "tray.full", tint: .secondary, monospaced: true)
                Spacer()
                DiffLayoutPicker()
                Menu {
                    Button("Rename Stash…") { store.stashAction(.rename(stash)) }
                    Button("Create Branch from Stash…") { store.stashAction(.branch(stash)) }
                    Divider()
                    Button("Recover Deleted Items…") { store.manage(.recovery) }
                    Button("Delete Stash…", role: .destructive) { store.stashAction(.delete(stash)) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More stash actions")
                Button("Apply…") { store.stashAction(.apply(stash)) }.buttonStyle(.borderedProminent).controlSize(.small).help("Apply this stash to the working copy")
            }.padding(.horizontal, 14).frame(height: Pico.headerHeight).background(.bar).overlay(alignment: .bottom) { Divider() }
            if let failure { InspectionErrorView(message: failure) }
            else if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        CommitSummaryHeader(message: stash.subject, author: detail.commit.author, email: detail.commit.email, date: detail.commit.date) {
                            HStack(spacing: 6) {
                                Text("Based on").foregroundStyle(.secondary)
                                HashChip(hash: detail.base, length: 7)
                                Spacer(minLength: 0)
                            }.font(.system(size: 11))
                        }
                        ChangedFilesHeader(count: detail.files.count, additions: detail.statistics.values.reduce(0) { $0 + $1.additions }, deletions: detail.statistics.values.reduce(0) { $0 + $1.deletions }, allExpanded: !detail.files.isEmpty && expanded.count == detail.files.count) {
                            expanded = expanded.count == detail.files.count ? [] : Set(detail.files.map(\.path))
                        } trailing: {
                            if !selected.isEmpty {
                                Label("Drag \(selected.count) to Working Copy", systemImage: "hand.draw").foregroundStyle(.secondary).font(.system(size: 11)).picoDrag(store, .stashFiles(stash, selected.sorted())).help("Drag to Working Copy to apply selected files")
                                Button("Apply \(selected.count) Selected…") { store.stashAction(.files(stash, selected.sorted())) }.controlSize(.small)
                            }
                        }
                        ForEach(detail.files) { file in
                            StashFileDisclosure(store: store, repository: repository, stash: stash, file: file, statistics: detail.statistics[file.path], expanded: Binding(get: { expanded.contains(file.path) }, set: { if $0 { expanded.insert(file.path) } else { expanded.remove(file.path) } }), selected: Binding(get: { selected.contains(file.path) }, set: { if $0 { selected.insert(file.path) } else { selected.remove(file.path) } }))
                        }
                    }
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task { do { detail = try await repository.stashDetail(stash) } catch { failure = error.localizedDescription } }
    }
}
