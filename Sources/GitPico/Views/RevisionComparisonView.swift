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
    init(store: RepositoryStore, repository: GitRepository, initialLeft: String, initialRight: String = "HEAD") {
        self.store = store; self.repository = repository
        _left = State(initialValue: initialLeft)
        _right = State(initialValue: initialRight)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 13, weight: .medium)).foregroundStyle(.tint)
                revisionField("From", text: $left)
                Button { swap(&left, &right) } label: { Image(systemName: "arrow.left.arrow.right.circle") }.buttonStyle(.borderless).help("Swap revisions")
                revisionField("To", text: $right)
                Menu {
                    Toggle("Compare from Merge Base", isOn: $mergeBase)
                    Toggle("Ignore Whitespace", isOn: $ignoreWhitespace)
                    Picker("Context Lines", selection: $context) { ForEach([3, 7, 15, 30], id: \.self) { Text("\($0) lines").tag($0) } }
                } label: { Image(systemName: mergeBase || ignoreWhitespace ? "ellipsis.circle.fill" : "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Comparison options")
                Button("Compare") { request = UUID() }.buttonStyle(.borderedProminent).disabled(loading || left.isEmpty || right.isEmpty).keyboardShortcut(.return, modifiers: [.command, .option])
            }.font(.system(size: 12)).padding(.horizontal, 14).frame(height: Pico.headerHeight).background(.bar).overlay(alignment: .bottom) { Divider() }
            if loading { ProgressView("Comparing revisions…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error { InspectionErrorView(message: error) }
            else if let comparison {
                PersistentSplitView(name: "comparison", width: 310) {
                    VStack(spacing: 0) {
                        PaneBar(title: "\(comparison.files.count) changed \(comparison.files.count == 1 ? "file" : "files")", subtitle: "\(comparison.left.prefix(8)) → \(comparison.right.prefix(8))", icon: "doc.on.doc") {
                            DiffStat(additions: comparison.statistics.values.reduce(0) { $0 + $1.additions }, deletions: comparison.statistics.values.reduce(0) { $0 + $1.deletions }, showsBar: false)
                        }
                        TextField("Filter files", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.vertical, 8)
                        List(selection: $selected) {
                            ForEach(files) { file in
                                HStack(spacing: 8) {
                                    StatusBadge(status: file.status)
                                    FilePathLabel(path: file.path)
                                    Spacer(minLength: 0)
                                    if let stats = comparison.statistics[file.path] { if stats.isBinary { Chip(text: "Binary", tint: .secondary) } else { DiffStat(additions: stats.additions, deletions: stats.deletions, showsBar: false) } }
                                }.tag(file.path).padding(.vertical, 3).contextMenu { Button("Compare in External Tool…") { store.externalTool(.comparison(comparison.left, comparison.right, file.path, comparison.originalPaths[file.path])) } }
                            }
                        }.listStyle(.plain)
                        if comparison.files.isEmpty { Text("These revisions have identical trees.").font(.caption).foregroundStyle(.secondary).padding() }
                    }
                } trailing: {
                    VStack(spacing: 0) {
                        if let diffError { InspectionErrorView(message: diffError) }
                        else if let path = selected, let repository = store.repository, comparison.statistics[path]?.isBinary == true || BinaryComparisonView.isImageCandidate(path) {
                            BinaryComparisonView(repository: repository, path: path, originalPath: comparison.originalPaths[path], left: .revision(comparison.left), right: .revision(comparison.right))
                        } else { DiffView(text: diff, title: selected, isLoading: loadingDiff) }
                    }
                }
            } else { EmptyPane(title: "Compare Revisions", subtitle: "Choose any two branches, tags or commit hashes, then press Compare.", icon: "arrow.left.arrow.right") }
        }
        .task(id: request) { await compare() }
        .task(id: "\(comparison?.left ?? ""):\(comparison?.right ?? ""):\(selected ?? ""):\(context):\(ignoreWhitespace)") { await loadDiff() }
    }
    private func revisionField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary).font(.system(size: 11, weight: .medium))
            TextField("Branch, tag, or commit", text: text).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
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
