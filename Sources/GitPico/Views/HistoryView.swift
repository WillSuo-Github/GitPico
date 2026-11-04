import GitCore
import SwiftUI

struct HistoryView: View {
    @Bindable var store: RepositoryStore
    @State private var preferences = AppPreferences.shared
    @State private var showingSearchFilters = false
    var commits: [Commit] { store.visibleCommits }
    var body: some View {
        PersistentSplitView(name: "history", width: 320) {
            VStack(spacing: 0) {
                PaneBar(title: store.destination.ref == nil ? "All Branches" : "\(store.destination.title)",
                        subtitle: store.destination.ref == nil ? String(localized: "Branches, remotes and tags · \(commits.count)\(store.historyPresentation.page.hasMore ? "+" : "") commits") : String(localized: "\(commits.count)\(store.historyPresentation.page.hasMore ? "+" : "") commits"),
                        icon: store.destination.ref == nil ? "clock.arrow.circlepath" : "arrow.triangle.branch") {
                    if let ref = store.previewedReference,
                       let sync = BranchSyncStatus.current(ref, snapshot: store.snapshot),
                       !sync.unavailable, sync.behind > 0 {
                        Chip(text: sync.behind.formatted(), icon: "arrow.down", tint: .accentColor)
                            .help(sync.help).accessibilityLabel(sync.help)
                    }
                    if let ref = store.previewedReference, !ref.isCurrent {
                        Chip(text: String(localized: "Preview"), icon: "eye", tint: .secondary)
                            .help("Viewing this revision does not change the checked-out branch.")
                        if ref.isLocal {
                            Button("Check Out") { store.switchBranch(ref) }.controlSize(.small)
                                .disabled(store.checkoutUnavailableReason(ref) != nil)
                                .help(store.checkoutUnavailableReason(ref) ?? (String(localized: "Switch the working copy to \(ref.name)")))
                        }
                    }
                    if store.isLoadingHistory { ProgressView().controlSize(.mini).help("Loading history…") }
                    Button { showingSearchFilters = true } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Search by author, date, file path or changed code")
                        .accessibilityLabel("Search history filters")
                        .popover(isPresented: $showingSearchFilters) { HistorySearchFilters(store: store) }
                    Menu {
                        Text("Search: author:\"Name\" after:2026-01-01 path:\"Sources/File.swift\" content:\"changed code\" hash:abcd message:\"fix\"")
                        Divider()
                        Toggle("Show Graph", isOn: $preferences.historyShowGraph)
                        Toggle("Show First Parent Only", isOn: $store.historyOptions.firstParent)
                        Divider()
                        Picker("Sort By", selection: $store.historyOptions.sortByDate) { Text("Topo Order").tag(false); Text("Date").tag(true) }
                        Toggle("Group by Month", isOn: $preferences.historyGroups)
                        Picker("Commit View Size", selection: $preferences.historyCompact) { Text("Medium").tag(false); Text("Small").tag(true) }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Change viewing options").disabled(store.isBusy)
                }
                if !store.search.isEmpty {
                    SearchScopeBar(title: String(localized: "Commit history · all reachable matches"), query: store.search) { store.search = "" }
                        .padding(10).background(.bar)
                }
                if store.selectedHistoryHashes.count > 1 {
                    HStack(spacing: 8) {
                        Text("\(store.selectedHistoryHashes.count) selected").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Cherry-Pick…") { store.reviewSelectedCommits(.cherryPick) }
                        Button("Revert…") { store.reviewSelectedCommits(.revert) }
                    }.controlSize(.small).padding(10).background(.bar).disabled(!store.canIntegrate)
                }
                if let failure = store.historyError, !commits.isEmpty {
                    HStack { Image(systemName: "exclamationmark.triangle"); Text(failure).lineLimit(2); Spacer(); Button("Retry") { store.requestHistory() } }
                        .font(.caption).padding(8).background(Pico.warning.opacity(0.1))
                }
                HistoryCommitTable(store: store, presentation: store.historyPresentation, grouped: preferences.historyGroups, compact: preferences.historyCompact, showGraph: preferences.historyShowGraph && store.search.isEmpty, canModifyHistory: store.canIntegrate, selection: store.selectedCommit?.hash, reveal: store.historyReveal)
                    .overlay { if commits.isEmpty { if store.isLoadingHistory { ProgressView("Loading history…") } else { EmptyPane(title: store.historyError ?? (store.search.isEmpty ? String(localized: "No commits yet") : String(localized: "No matching commits")), subtitle: store.search.isEmpty ? "" : String(localized: "Try a different message, author or hash."), icon: store.search.isEmpty ? "clock" : "magnifyingglass") } } }
                if store.historyPresentation.page.hasMore {
                    if store.historyOptions.limit < 20_000 {
                        Button("Load More · \(commits.count) shown", action: store.loadMoreHistory).frame(maxWidth: .infinity).padding(8).disabled(store.isLoadingHistory || store.isBusy)
                    } else {
                        Text("Showing the first 20,000 matches. Narrow the search to find older commits.").font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
            }
        } trailing: {
            CommitDetailView(store: store)
        }
        .onChange(of: store.historyOptions.firstParent) { store.requestHistory() }
        .onChange(of: store.historyOptions.sortByDate) { store.requestHistory() }
    }
}

/// Built only when a context menu opens, rather than for every history row update.
struct HistoryCommitActions: View {
    let store: RepositoryStore
    let commit: Commit
    let canModifyHistory: Bool
    var body: some View {
        if store.selectedHistoryHashes.contains(commit.hash), store.selectedHistoryHashes.count > 1 {
            Section {
                Button("Cherry-Pick Selected Commits…") { store.reviewSelectedCommits(.cherryPick) }
                Button("Revert Selected Commits…") { store.reviewSelectedCommits(.revert) }
            }.disabled(!canModifyHistory)
        }
        Section {
            Button("Cherry-Pick Commit…") { store.integrationRequest = IntegrationRequest(action: .cherryPick, revision: commit.hash) }
            Button("Revert Commit…") { store.integrationRequest = IntegrationRequest(action: .revert, revision: commit.hash) }
            Button("Compare with Revision…") { store.navigate(.comparison(commit.hash)) }
            Button("Prepare Fixup for This Commit") { store.prepareFixup(commit) }
            Button("Interactively Rebase from Here…") { store.rebaseRequest = RebaseRequest(base: commit.parents.first ?? "--root") }
            Button("Restore HEAD Here…") { store.recoveryRequest = RecoveryRequest(action: .restore(commit.hash)) }
            Button("Create Branch Here…") { store.recoveryRequest = RecoveryRequest(action: .branch(commit.hash)) }
        }.disabled(!canModifyHistory)
        Section {
            Button("Export Files at Revision…") { store.historical(.export, revision: commit.hash) }
            Button("Archive Files as ZIP…") { store.historical(.archive, revision: commit.hash) }
            Button("Save Patch as File…") { store.localChange(.export(.commit(commit.hash), [])) }
        }
        Section {
            Button("Copy Commit Hash") { Pico.copy(commit.hash) }
            Button("Copy Commit Subject") { Pico.copy(commit.subject) }
        }
    }
}

extension RepositoryStore {
    func reviewSelectedCommits(_ action: GitRepository.Integration) {
        guard canIntegrate else { return }
        let commits = visibleCommits.filter { selectedHistoryHashes.contains($0.hash) }
        guard (1...200).contains(commits.count) else { error = String(localized: "Choose up to 200 commits for one batch."); return }
        batchIntegrationRequest = BatchIntegrationRequest(action: action, commits: action == .cherryPick ? commits.reversed() : commits)
    }
}
