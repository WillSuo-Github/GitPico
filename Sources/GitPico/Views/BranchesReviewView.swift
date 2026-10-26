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
    var visible: [BranchComparison] { comparisons.filter { store.search.isEmpty || $0.branch.name.localizedCaseInsensitiveContains(store.search) } }
    var baseName: String { branches.first { $0.fullName == base }?.name ?? base }
    var body: some View {
        VStack(spacing: 0) {
            PaneBar(title: "Branches Review", subtitle: "\(comparisons.count) local \(comparisons.count == 1 ? "branch" : "branches") compared with \(baseName) · \(comparisons.filter(\.isMerged).count) merged", icon: "arrow.left.arrow.right") {
                Text("Base").foregroundStyle(.secondary).font(.system(size: 11))
                Picker("Base branch", selection: $base) { ForEach(branches) { Text($0.name).tag($0.fullName) } }.labelsHidden().fixedSize()
            }
            PersistentSplitView(name: "branchesReview", width: 300, minimum: 240) {
                List(selection: $selected) {
                    ForEach(visible, id: \.branch.id) { comparison in
                        HStack(spacing: 10) {
                            Image(systemName: comparison.isMerged ? "checkmark.circle.fill" : "arrow.triangle.branch")
                                .font(.system(size: 14)).foregroundStyle(comparison.isMerged ? Pico.addition : Color.accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(comparison.branch.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                Text(comparison.branch.upstream.isEmpty ? "No tracking branch" : comparison.branch.upstream).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            AheadBehind(ahead: comparison.ahead, behind: comparison.behind)
                        }.padding(.vertical, 5).tag(comparison.branch.id)
                    }
                }.listStyle(.plain)
                .overlay { if comparisons.isEmpty, failure == nil { EmptyPane(title: branches.count < 2 ? "Only one branch" : "Comparing…", subtitle: branches.count < 2 ? "Create another local branch to review it against \(baseName)." : "", icon: "arrow.triangle.branch") } }
            } trailing: {
                VStack(alignment: .leading, spacing: 0) {
                    if let item = comparisons.first(where: { $0.branch.id == selected }) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Chip(text: item.branch.name, icon: "arrow.triangle.branch", tint: Pico.modified)
                                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                Chip(text: baseName, icon: "arrow.triangle.branch", tint: .secondary)
                                Spacer()
                                Button("Show History") { store.navigate(.reference(item.branch.fullName)) }.controlSize(.small)
                                if !item.branch.isCurrent { Button("Check Out") { store.switchBranch(item.branch) }.controlSize(.small).buttonStyle(.borderedProminent) }
                            }
                            HStack(spacing: 18) {
                                stat("\(item.ahead)", "ahead", Color.accentColor)
                                stat("\(item.behind)", "behind", .secondary)
                                stat("\(item.files.count)", item.files.count == 1 ? "file" : "files", Pico.modified)
                                Spacer()
                                Label(item.isMerged ? "Fully merged into \(baseName)" : "Has changes not in \(baseName)", systemImage: item.isMerged ? "checkmark.seal.fill" : "exclamationmark.circle")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(item.isMerged ? Pico.addition : Pico.warning)
                            }.card(padding: 12)
                            Picker("Detail", selection: $changeset) { Text("Commits").tag(false); Text("Changed Files").tag(true) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                        }.padding(18)
                        Divider()
                        List {
                            if changeset { ForEach(item.files) { file in HStack(spacing: 8) { StatusBadge(status: file.status); FilePathLabel(path: file.path) }.padding(.vertical, 2) } }
                            else { ForEach(item.commits) { commit in
                                Button { store.navigate(.reference(item.branch.fullName)); store.selectCommit(commit) } label: {
                                    HStack(spacing: 10) {
                                        AuthorAvatar(name: commit.author, size: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(commit.subject).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                            Text(commit.author + " · " + commit.shortHash + " · " + commit.date.picoRelative).font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(.vertical, 3).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            } }
                        }.listStyle(.plain)
                        .overlay { if (changeset ? item.files.isEmpty : item.commits.isEmpty) { EmptyPane(title: changeset ? "No file differences" : "No unique commits", subtitle: "Everything on this branch is already in \(baseName).", icon: "checkmark.seal") } }
                    } else if let failure { InspectionErrorView(message: failure) }
                    else { EmptyPane(title: "Select a branch", subtitle: "See how far it has drifted from \(baseName) and what would be merged.", icon: "arrow.triangle.branch") }
                }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
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

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(tint)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Compact ↑ahead ↓behind capsule.
struct AheadBehind: View {
    let ahead: Int
    let behind: Int
    var body: some View {
        HStack(spacing: 6) {
            Label("\(ahead)", systemImage: "arrow.up").foregroundStyle(ahead > 0 ? Color.accentColor : Color.secondary.opacity(0.6))
            Label("\(behind)", systemImage: "arrow.down").foregroundStyle(behind > 0 ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.6))
        }
        .labelStyle(AheadBehindLabelStyle()).font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .help("\(ahead) commits ahead · \(behind) commits behind")
    }
}
private struct AheadBehindLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 1) { configuration.icon.imageScale(.small); configuration.title } }
}
