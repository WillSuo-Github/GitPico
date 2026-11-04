import GitCore
import SwiftUI

struct BatchIntegrationRequest: Identifiable {
    let id = UUID()
    let action: GitRepository.Integration
    let commits: [Commit]
}

struct BatchIntegrationSheet: View {
    let store: RepositoryStore
    let request: BatchIntegrationRequest
    @Environment(\.dismiss) private var dismiss
    @State private var commits: [Commit]
    @State private var expectedHead: HeadPosition?
    @State private var mainline = 1
    @State private var error: String?
    init(store: RepositoryStore, request: BatchIntegrationRequest) {
        self.store = store; self.request = request; _commits = State(initialValue: request.commits)
    }
    private var merges: [Commit] { commits.filter { $0.parents.count > 1 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle("\(request.action.title) \(commits.count) Commits")
            LabeledContent("Current branch", value: expectedHead?.branch.replacingOccurrences(of: "refs/heads/", with: "") ?? "…")
            Text("Commits run from top to bottom. Drag to reorder, or use the arrow buttons. Conflicts pause the batch for Continue or Abort; completed work is included in Git Undo.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(Array(commits.enumerated()), id: \.element.hash) { index, commit in
                    HStack {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(commit.subject).lineLimit(2)
                            Text(commit.shortHash + " · " + commit.author).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { commits.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).help("Move commit earlier").accessibilityLabel("Move commit earlier")
                        Button { commits.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == commits.count - 1).help("Move commit later").accessibilityLabel("Move commit later")
                    }.padding(.vertical, 4)
                }.onMove { commits.move(fromOffsets: $0, toOffset: $1) }
            }.listStyle(.bordered).buttonStyle(.borderless)
            if !merges.isEmpty {
                Picker("Mainline parent for merge commits", selection: $mainline) {
                    ForEach(1...(merges.map { $0.parents.count }.min() ?? 1), id: \.self) { Text("Parent \($0)").tag($0) }
                }
                Text("The selected parent number applies to each merge commit. Review merges individually if they need different mainline parents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(Pico.deletion).textSelection(.enabled) }
            if !store.changes.isEmpty { Text("Commit or stash local changes before running this batch.").foregroundStyle(Pico.warning) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("\(request.action.title) \(commits.count) Commits") {
                    guard let expectedHead else { return }
                    let action = request.action, hashes = commits.map(\.hash), parent = merges.isEmpty ? nil : mainline
                    store.perform("\(action.progressTitle)", refresh: .workingTree) {
                        try await $0.integrateBatch(action, revisions: hashes, mainline: parent, expectedHead: expectedHead)
                    }
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(expectedHead == nil || !store.canIntegrate || !store.changes.isEmpty || commits.isEmpty || commits.count > 200)
            }
        }.padding(24).frame(width: 660, height: 560)
            .task {
                do { expectedHead = try await store.repository?.headPosition() }
                catch { self.error = error.localizedDescription }
            }
    }
}
