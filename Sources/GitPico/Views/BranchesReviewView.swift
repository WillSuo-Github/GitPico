import GitCore
import SwiftUI

struct BranchesReviewView: View {
    @Bindable var store: RepositoryStore
    @State private var base = ""
    @State private var selected: String?
    @State private var comparisons: [BranchComparison] = []
    @State private var failure: String?
    @State private var changeset = false
    var branches: [Reference] { (store.snapshot?.references ?? []).filter(\.isLocal) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Compare local branches to:").foregroundStyle(.secondary)
                Picker("Base branch", selection: $base) { ForEach(branches) { Text($0.name).tag($0.fullName) } }.labelsHidden().frame(width: 200)
                Spacer()
            }.font(.system(size: 12)).padding(.horizontal, 16).frame(height: 42).background(.bar)
            Divider()
            PersistentSplitView(name: "branchesReview", width: 245, minimum: 220) {
                List(selection: $selected) {
                    ForEach(comparisons.filter { store.search.isEmpty || $0.branch.name.localizedCaseInsensitiveContains(store.search) }, id: \.branch.id) { comparison in
                        HStack(spacing: 9) {
                            Image(systemName: comparison.isMerged ? "checkmark.circle" : "arrow.triangle.merge").foregroundStyle(comparison.isMerged ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(comparison.branch.name).font(.system(size: 12))
                                Text("↑\(comparison.ahead)  ↓\(comparison.behind)   \(comparison.branch.upstream.isEmpty ? "No tracking branch" : comparison.branch.upstream)").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6).tag(comparison.branch.id)
                    }
                }.listStyle(.plain)
            } trailing: {
                VStack(alignment: .leading, spacing: 12) {
                    if let item = comparisons.first(where: { $0.branch.id == selected }) {
                        HStack { Text(item.branch.name).font(.headline); Image(systemName: "arrow.right"); Text(branches.first { $0.fullName == base }?.name ?? base); Spacer() }
                        Text("\(item.ahead) commits ahead, \(item.behind) commits behind").foregroundStyle(.secondary)
                        Text(item.isMerged ? "Fully merged into the base branch" : "Changes not yet in the base branch").font(.callout)
                        Picker("Detail", selection: $changeset) { Text("Commits").tag(false); Text("Changeset").tag(true) }.pickerStyle(.segmented).frame(width: 200)
                        Divider()
                        List {
                            if changeset { ForEach(item.files) { file in HStack { StatusBadge(status: file.status); Text(file.path).font(.system(size: 12)) } } }
                            else { ForEach(item.commits) { commit in Button { store.navigate(.reference(item.branch.fullName)); store.selectCommit(commit) } label: { VStack(alignment: .leading, spacing: 5) { Text(commit.subject); Text(commit.shortHash + "  " + commit.author).font(.caption).foregroundStyle(.secondary) } }.buttonStyle(.plain) } }
                        }.listStyle(.plain)
                        HStack {
                            Button("Show History") { store.navigate(.reference(item.branch.fullName)) }
                            if !item.branch.isCurrent { Button("Check Out") { store.switchBranch(item.branch) } }
                            Spacer()
                        }
                    } else if let failure { Text(failure).foregroundStyle(.red) }
                    else { EmptyPane(title: "Select a branch", subtitle: "", icon: "arrow.triangle.branch") }
                }.padding(18).frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
        }.task(id: base + (store.snapshot?.branch ?? "") + String(store.snapshot?.commits.count ?? 0)) {
            guard let repository = store.repository else { return }
            if base.isEmpty { base = branches.first(where: { $0.name == "main" || $0.name == "master" })?.fullName ?? branches.first?.fullName ?? ""; return }
            do {
                var result: [BranchComparison] = []
                for branch in branches where branch.fullName != base {
                    let comparison = try await repository.compare(branch, to: base)
                    guard !Task.isCancelled else { return }
                    result.append(comparison)
                }
                comparisons = result
                if selected == nil || !result.contains(where: { $0.branch.id == selected }) { selected = result.first?.branch.id }
            } catch { failure = error.localizedDescription }
        }
    }
}
