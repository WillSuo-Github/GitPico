import GitCore
import SwiftUI

struct HistoryView: View {
    @Bindable var store: RepositoryStore
    @State private var preferences = AppPreferences.shared
    var commits: [Commit] { store.visibleCommits }
    var body: some View {
        PersistentSplitView(name: "history", width: 320) {
            VStack(spacing: 0) {
                PaneBar(title: store.destination.ref == nil ? "All Branches" : store.destination.title,
                        subtitle: store.destination.ref == nil ? "Branches, remotes and tags · \(commits.count)\(store.historyPresentation.page.hasMore ? "+" : "") commits" : "\(commits.count)\(store.historyPresentation.page.hasMore ? "+" : "") commits",
                        icon: store.destination.ref == nil ? "clock.arrow.circlepath" : "arrow.triangle.branch") {
                    if let ref = store.previewedReference, !ref.isCurrent {
                        Chip(text: "Preview", icon: "eye", tint: .secondary)
                            .help("Viewing this revision does not change the checked-out branch.")
                        if ref.isLocal {
                            Button("Check Out") { store.switchBranch(ref) }.controlSize(.small)
                                .disabled(store.checkoutUnavailableReason(ref) != nil)
                                .help(store.checkoutUnavailableReason(ref) ?? ("Switch the working copy to " + ref.name))
                        }
                    }
                    if store.isLoadingHistory { ProgressView().controlSize(.mini).help("Loading history…") }
                    Menu {
                        Text("Search: author:\"Name\" after:2026-01-01 before:2026-12-31 path:\"Sources/File.swift\" hash:abcd message:\"fix\"")
                        Divider()
                        Toggle("Show Graph", isOn: $preferences.historyShowGraph)
                        Toggle("Show First Parent Only", isOn: $store.historyOptions.firstParent)
                        Divider()
                        Picker("Sort By", selection: $store.historyOptions.sortByDate) { Text("Topo Order").tag(false); Text("Date").tag(true) }
                        Toggle("Group by Month", isOn: $preferences.historyGroups)
                        Picker("Commit View Size", selection: $preferences.historyCompact) { Text("Medium").tag(false); Text("Small").tag(true) }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Change viewing options").disabled(store.isBusy)
                }
                if let failure = store.historyError, !commits.isEmpty {
                    HStack { Image(systemName: "exclamationmark.triangle"); Text(failure).lineLimit(2); Spacer(); Button("Retry") { store.requestHistory() } }
                        .font(.caption).padding(8).background(Pico.warning.opacity(0.1))
                }
                HistoryCommitTable(store: store, presentation: store.historyPresentation, grouped: preferences.historyGroups, compact: preferences.historyCompact, showGraph: preferences.historyShowGraph && store.search.isEmpty, canModifyHistory: store.canIntegrate, selection: store.selectedCommit?.hash, reveal: store.historyReveal)
                    .overlay { if commits.isEmpty { if store.isLoadingHistory { ProgressView("Loading history…") } else { EmptyPane(title: store.historyError ?? (store.search.isEmpty ? "No commits yet" : "No matching commits"), subtitle: store.search.isEmpty ? "" : "Try a different message, author or hash.", icon: store.search.isEmpty ? "clock" : "magnifyingglass") } } }
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
