import GitCore
import SwiftUI

struct RevisionComparisonView: View {
    @Bindable var store: RepositoryStore
    let repository: GitRepository
    @State private var left = "HEAD~1"
    @State private var right = "HEAD"
    @State private var mergeBase = false
    @State private var comparison: RevisionComparison?
    @State private var selected: String?
    @State private var query = ""
    @State private var diff = ""
    @State private var error: String?
    @State private var diffError: String?
    @State private var loading = false
    @State private var loadingDiff = false
    @State private var request = UUID()
    @State private var context = 7
    @State private var ignoreWhitespace = false
    var files: [ChangedPath] { (comparison?.files ?? []).filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) } }
    init(store: RepositoryStore, repository: GitRepository, initialLeft: String) {
        self.store = store; self.repository = repository
        _left = State(initialValue: initialLeft)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                revisionField("From", text: $left)
                Button { swap(&left, &right) } label: { Image(systemName: "arrow.left.arrow.right") }.help("Swap revisions")
                revisionField("To", text: $right)
                Toggle("From Merge Base", isOn: $mergeBase).toggleStyle(.checkbox).fixedSize().help("Compare the common ancestor of From and To with To")
                Button("Compare") { request = UUID() }.disabled(loading || left.isEmpty || right.isEmpty).keyboardShortcut(.return, modifiers: [.command, .option])
            }.font(.system(size: 12)).padding(14).background(.bar)
            Divider()
            if loading { ProgressView("Comparing revisions…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error { InspectionErrorView(message: error) }
            else if let comparison {
                PersistentSplitView(name: "comparison", width: 310) {
                    VStack(spacing: 0) {
                        PaneHeader(title: "\(comparison.files.count) changed files", subtitle: "\(comparison.left.prefix(8)) → \(comparison.right.prefix(8))", icon: "arrow.left.arrow.right")
                        TextField("Filter files", text: $query).textFieldStyle(.roundedBorder).padding(10)
                        List(selection: $selected) {
                            ForEach(files) { file in
                                HStack(spacing: 8) {
                                    StatusBadge(status: file.status)
                                    Text(file.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    if let stats = comparison.statistics[file.path] { Text(stats.isBinary ? "Binary" : "+\(stats.additions) −\(stats.deletions)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                                }.tag(file.path).padding(.vertical, 3).contextMenu { Button("Compare in External Tool…") { store.externalTool(.comparison(comparison.left, comparison.right, file.path, comparison.originalPaths[file.path])) } }
                            }
                        }.listStyle(.plain)
                        if comparison.files.isEmpty { Text("These revisions have identical trees.").font(.caption).foregroundStyle(.secondary).padding() }
                    }
                } trailing: {
                    VStack(spacing: 0) {
                        HStack {
                            Text("\(comparison.left.prefix(12)) → \(comparison.right.prefix(12))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            Picker("Context", selection: $context) { ForEach([3, 7, 15, 30], id: \.self) { Text("\($0) lines").tag($0) } }.frame(width: 130)
                            Toggle("Ignore Whitespace", isOn: $ignoreWhitespace).toggleStyle(.checkbox).font(.caption)
                        }.padding(10).background(.bar)
                        Divider()
                        if let diffError { InspectionErrorView(message: diffError) }
                        else { DiffView(text: diff, title: selected, isLoading: loadingDiff) }
                    }
                }
            } else { EmptyPane(title: "Compare Revisions", subtitle: "Choose any two branches, tags, or commit hashes.", icon: "arrow.left.arrow.right") }
        }
        .task(id: request) { await compare() }
        .task(id: "\(comparison?.left ?? ""):\(comparison?.right ?? ""):\(selected ?? ""):\(context):\(ignoreWhitespace)") { await loadDiff() }
    }
    private func revisionField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            TextField("Branch, tag, or commit", text: text).textFieldStyle(.roundedBorder)
            Menu {
                Button("HEAD") { text.wrappedValue = "HEAD" }
                ForEach(store.snapshot?.references ?? []) { ref in Button(ref.name) { text.wrappedValue = ref.fullName } }
            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize()
        }
    }
    private func compare() async {
        loading = true; error = nil; comparison = nil; selected = nil; diff = ""
        defer { if !Task.isCancelled { loading = false } }
        do {
            let value = try await repository.compareRevisions(left: left, right: right, useMergeBase: mergeBase)
            guard !Task.isCancelled else { return }
            comparison = value; selected = value.files.first?.path
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func loadDiff() async {
        guard let comparison, let selected else { return }
        loadingDiff = true; diff = ""; diffError = nil
        defer { if !Task.isCancelled { loadingDiff = false } }
        do {
            let value = try await repository.comparisonDiff(comparison, path: selected, context: context, ignoreWhitespace: ignoreWhitespace)
            guard !Task.isCancelled else { return }; diff = value
        } catch { if !Task.isCancelled { diffError = error.localizedDescription } }
    }
}
