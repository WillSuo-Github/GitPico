import GitCore
import SwiftUI

struct HistoryView: View {
    @Bindable var store: RepositoryStore
    @State private var preferences = AppPreferences.shared
    var commits: [Commit] { store.visibleCommits }
    var groups: [HistoryGroup] { preferences.historyGroups ? store.historyPresentation.groups : [HistoryGroup(id: "all", title: "", commits: commits)] }
    var body: some View {
        PersistentSplitView(name: "history", width: 320) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text(store.destination.ref == nil ? "All Branches, Remotes, Tags" : store.destination.title).lineLimit(1)
                    Spacer(minLength: 0)
                    if let ref = store.previewedReference, !ref.isCurrent {
                        Text("Preview").font(.caption2).foregroundStyle(.secondary)
                            .help("Viewing this revision does not change the checked-out branch.")
                        if ref.isLocal {
                            Button("Check Out") { store.switchBranch(ref) }
                                .disabled(store.checkoutUnavailableReason(ref) != nil)
                                .help(store.checkoutUnavailableReason(ref) ?? ("Switch the working copy to " + ref.name))
                        }
                    }
                    if store.isLoadingHistory { ProgressView().controlSize(.mini).help("Loading history…") }
                    Menu {
                        Toggle("Show Graph", isOn: $preferences.historyShowGraph)
                        Toggle("Show First Parent Only", isOn: $store.historyOptions.firstParent)
                        Divider()
                        Picker("Sort By", selection: $store.historyOptions.sortByDate) { Text("Topo Order").tag(false); Text("Date").tag(true) }
                        Toggle("Group by Month", isOn: $preferences.historyGroups)
                        Picker("Commit View Size", selection: $preferences.historyCompact) { Text("Medium").tag(false); Text("Small").tag(true) }
                    } label: { Image(systemName: "slider.horizontal.3") }.menuStyle(.borderlessButton).frame(width: 20).help("Change viewing options").disabled(store.isBusy)
                }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 40).background(.bar)
                Divider()
                if let failure = store.historyError, !commits.isEmpty {
                    HStack { Image(systemName: "exclamationmark.triangle"); Text(failure).lineLimit(2); Spacer(); Button("Retry") { store.requestHistory() } }
                        .font(.caption).padding(8).background(.yellow.opacity(0.1))
                }
                let graph = store.historyPresentation.graph
                let width = CGFloat(store.historyPresentation.graphWidth)
                ScrollViewReader { proxy in
                List(selection: Binding(get: { store.selectedCommit?.id }, set: { id in if let commit = commits.first(where: { $0.id == id }) { store.selectCommit(commit) } })) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.commits) { commit in
                                CommitRow(commit: commit, graph: graph[commit.hash], graphWidth: width, compact: preferences.historyCompact, showGraph: preferences.historyShowGraph && store.search.isEmpty, selected: store.selectedCommit?.id == commit.id, canModifyHistory: store.canIntegrate, cherryPick: { store.integrationRequest = IntegrationRequest(action: .cherryPick, revision: commit.hash) }, interactiveRebase: commit.parents.isEmpty || store.snapshot?.operation != RepositoryOperation.none ? nil : { store.rebaseRequest = RebaseRequest(base: commit.parents.first) }, restore: { store.recoveryRequest = RecoveryRequest(action: .restore(commit.hash)) }, recoverBranch: { store.recoveryRequest = RecoveryRequest(action: .branch(commit.hash)) }, revert: { store.integrationRequest = IntegrationRequest(action: .revert, revision: commit.hash) }, compare: { store.navigate(.comparison(commit.hash)) }, savePatch: { store.localChange(.export(.commit(commit.hash), [])) }, exportFiles: { store.historical(.export, revision: commit.hash) }, archiveFiles: { store.historical(.archive, revision: commit.hash) })
                                    .picoDrag(store, .commit(commit))
                                    .picoDrop(store, .commit(commit, .squash))
                                    .tag(commit.id).id(commit.id).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                            }
                        } header: { if !group.title.isEmpty { Text(group.title).font(.system(size: 11)).foregroundStyle(.secondary) } }
                    }
                    if store.historyPresentation.page.hasMore && store.historyOptions.limit < 20_000 {
                        Button("Load More · \(commits.count) shown", action: store.loadMoreHistory).frame(maxWidth: .infinity).disabled(store.isLoadingHistory || store.isBusy)
                    }
                    if store.historyPresentation.page.hasMore && store.historyOptions.limit >= 20_000 {
                        Text("Showing the first 20,000 matches. Narrow the search to find older commits.").font(.caption).foregroundStyle(.secondary)
                    }
                }.listStyle(.plain).environment(\.defaultMinListRowHeight, preferences.historyCompact ? 32 : 48)
                .overlay { if commits.isEmpty { if store.isLoadingHistory { ProgressView("Loading history…") } else { EmptyPane(title: store.historyError ?? (store.search.isEmpty ? "No commits yet" : "No matching commits"), subtitle: "", icon: "clock") } } }
                .onChange(of: store.historyReveal, initial: true) {
                    guard let request = store.historyReveal else { return }
                    Task { @MainActor in
                        await Task.yield()
                        guard store.historyReveal == request else { return }
                        proxy.scrollTo(request.hash, anchor: request.atTop ? .top : .center)
                    }
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
