import GitCore
import SwiftUI
import AppKit

private struct MergeParentComparison: Identifiable {
    let id = UUID()
    let parent: String
    let commit: String
}

struct CommitDetailView: View {
    @Bindable var store: RepositoryStore
    @State private var tree = false
    @State private var metadataExpanded = false
    @State private var expandedFiles: Set<String> = []
    @State private var parentComparison: MergeParentComparison?
    @State private var detailEntered = false

    init(store: RepositoryStore, initialTree: Bool = false) {
        self.store = store
        _tree = State(initialValue: initialTree)
    }
    var body: some View {
        Group {
            if let commit = store.selectedCommit {
                PinnedScrollPane { insets in
                    if let detail = store.commitDetail {
                        if tree, let repository = store.repository {
                            CommitFilesTreeView(
                                store: store,
                                repository: repository,
                                commit: commit,
                                detail: detail,
                                showHistory: { store.navigate(.fileHistory($0, commit.hash)) },
                                topInset: insets.top,
                                bottomInset: insets.bottom
                            )
                            .id(commit.hash)
                        } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                CommitSummaryHeader(message: detail.message, author: detail.metadata.author, email: detail.metadata.authorEmail, date: detail.metadata.authorDate, decorations: commit.decorations) {
                                    HStack(spacing: 6) {
                                        Text(commit.parents.count > 1 ? "Parents" : "Parent").foregroundStyle(.secondary)
                                        if commit.parents.isEmpty { Text("Root commit").foregroundStyle(.tertiary) }
                                        ForEach(commit.parents, id: \.self) { HashChip(hash: $0, length: 7) }
                                        Spacer(minLength: 0)
                                        Button { withAnimation(.snappy) { metadataExpanded.toggle() } } label: {
                                            Label(metadataExpanded ? "Less" : "Details", systemImage: metadataExpanded ? "chevron.up" : "chevron.down").labelStyle(.titleAndIcon)
                                        }.buttonStyle(.borderless).help("Show committer, dates and tree")
                                    }.font(.system(size: 11))
                                    if metadataExpanded {
                                        if let repository = store.repository { SignatureVerificationView(repository: repository, revision: commit.hash).id(commit.hash) }
                                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                                            MetadataRow(label: "Author", value: "\(detail.metadata.author) <\(detail.metadata.authorEmail)>")
                                            MetadataRow(label: "Authored", value: detail.metadata.authorDate.formatted(date: .long, time: .standard))
                                            MetadataRow(label: "Committer", value: "\(detail.metadata.committer) <\(detail.metadata.committerEmail)>")
                                            MetadataRow(label: "Committed", value: detail.metadata.committerDate.formatted(date: .long, time: .standard))
                                            MetadataRow(label: "Commit", value: commit.hash, monospaced: true)
                                            MetadataRow(label: "Tree", value: detail.metadata.tree, monospaced: true)
                                        }.card(padding: 12).transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                                .staggeredEntrance(isShowing: detailEntered, index: 0, style: .card)
                                ChangedFilesHeader(count: detail.files.count, additions: detail.additions, deletions: detail.deletions, allExpanded: !detail.files.isEmpty && expandedFiles.count == detail.files.count) {
                                    expandedFiles = expandedFiles.count == detail.files.count ? [] : Set(detail.files.map(\.path))
                                }
                                .staggeredEntrance(isShowing: detailEntered, index: 1, style: .card)
                                if let repository = store.repository {
                                    ForEach(Array(detail.files.enumerated()), id: \.element.id) { index, file in
                                        CommitFileDisclosure(store: store, repository: repository, commit: commit, file: file, showHistory: { store.navigate(.fileHistory(file.path, commit.hash)) }, stats: detail.statistics[file.path], expanded: Binding(get: { expandedFiles.contains(file.path) }, set: { if $0 { expandedFiles.insert(file.path) } else { expandedFiles.remove(file.path) } }))
                                            .staggeredEntrance(isShowing: detailEntered, index: index, style: .item, delay: 0.06 + Double(min(index, 8)) * 0.025)
                                    }
                                }
                            }
                        }.pinnedScrollInsets(insets)
                        .staggeredEntranceTrigger($detailEntered, id: commit.hash)
                        }
                    } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).padding(insets) }
                } top: {
                    HStack(spacing: 8) {
                        HashChip(hash: commit.hash)
                        if commit.parents.count > 1 { Chip(text: String(localized: "Merge"), icon: "arrow.triangle.merge", tint: .purple) }
                        Spacer()
                        if commit.parents.count > 1 {
                            Menu("Compare Parent") {
                                ForEach(Array(commit.parents.enumerated()), id: \.offset) { index, parent in
                                    Button("Parent \(index + 1) · \(String(parent.prefix(8)))") { parentComparison = MergeParentComparison(parent: parent, commit: commit.hash) }
                                }
                            }.fixedSize().controlSize(.small).help("Compare the merge result with a specific parent")
                        }
                        if store.destination == .reflog {
                            Menu("Recover") {
                                Button("Create Branch Here…") { store.recoveryRequest = RecoveryRequest(action: .branch(commit.hash)) }
                                Button("Restore HEAD Here…") { store.recoveryRequest = RecoveryRequest(action: .restore(commit.hash)) }
                            }.fixedSize().controlSize(.small)
                        }
                        DiffLayoutPicker()
                        Picker("View", selection: $tree) { Text("Changes").tag(false); Text("Files").tag(true) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    }.padding(.horizontal, 14).frame(height: Pico.headerHeight)
                    .overlay(alignment: .bottom) { if tree { Divider() } }
                }
            } else {
                EmptyPane(title: String(localized: "Select a commit"), subtitle: String(localized: "Pick a commit to read its message and review every changed file."), icon: "clock.arrow.circlepath")
            }

        }
        .onChange(of: store.selectedCommit?.id) { expandedFiles = [] }
        .sheet(item: $parentComparison) { request in
            if let repository = store.repository {
                VStack(spacing: 12) {
                    HStack { SheetTitle("Merge Parent Comparison", icon: "arrow.triangle.merge"); Spacer(); Button("Close") { parentComparison = nil }.keyboardShortcut(.cancelAction) }
                    RevisionComparisonView(store: store, repository: repository, initialLeft: request.parent, initialRight: request.commit)
                }.padding(20).frame(width: 1060, height: 720)
                    .environment(\.repositoryStatusBarInset, 0)
            }
        }
    }
}

/// Message first, then who and when; extra rows (hashes, details) go in the trailing slot.
struct CommitSummaryHeader<Extra: View>: View {
    let message: String
    let author: String
    let email: String
    let date: Date
    var decorations: [String] = []
    @ViewBuilder var extra: Extra
    var subject: String { message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? message }
    var bodyText: String {
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
    var refs: [String] { decorations.flatMap { $0.hasPrefix("HEAD -> ") ? ["HEAD", String($0.dropFirst(8))] : [$0] } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(subject).font(.system(size: 17, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !bodyText.isEmpty { Text(bodyText).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
            if !refs.isEmpty {
                HStack(spacing: 5) {
                    ForEach(refs, id: \.self) { ref in
                        let tag = ref.hasPrefix("tag: ")
                        Chip(text: tag ? String(ref.dropFirst(5)) : ref, icon: tag ? "tag.fill" : ref == "HEAD" ? "smallcircle.filled.circle" : "arrow.triangle.branch", tint: ref == "HEAD" ? .accentColor : tag ? Pico.warning : Pico.modified, filled: ref == "HEAD")
                    }
                }
            }
            HStack(spacing: 10) {
                AuthorAvatar(name: author, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(author).font(.system(size: 12, weight: .semibold))
                    Text(email).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(date.picoRelative).font(.system(size: 12, weight: .medium))
                    Text(date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            extra
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
    }
}

/// "N files changed  +a −d" with an Expand/Collapse toggle.
struct ChangedFilesHeader<Trailing: View>: View {
    let count: Int
    let additions: Int
    let deletions: Int
    let allExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            Text("\(count) files changed").font(.system(size: 12, weight: .semibold))
            DiffStat(additions: additions, deletions: deletions)
            Spacer()
            trailing
            Button(allExpanded ? "Collapse All" : "Expand All", action: toggle).buttonStyle(.borderless).font(.system(size: 11)).disabled(count == 0)
        }
        .padding(.horizontal, 16).frame(height: 34)
        .overlay(alignment: .top) { Divider() }
    }
}
extension ChangedFilesHeader where Trailing == EmptyView {
    init(count: Int, additions: Int, deletions: Int, allExpanded: Bool, toggle: @escaping () -> Void) {
        self.init(count: count, additions: additions, deletions: deletions, allExpanded: allExpanded, toggle: toggle) { EmptyView() }
    }
}

struct CommitFileDisclosure: View {
    @Bindable var store: RepositoryStore
    let repository: GitRepository
    let commit: Commit
    let file: ChangedPath
    var showHistory: (() -> Void)? = nil
    let stats: FileStatistics?
    @Binding var expanded: Bool
    @State private var diff: String?
    @State private var prepared: PreparedPatch?
    @State private var error: String?
    @State private var contentWidth: CGFloat = 0
    @State private var preferences = AppPreferences.shared
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            DisclosureGroup(isExpanded: $expanded) {
                if stats?.isBinary == true || BinaryComparisonView.isImageCandidate(file.path) {
                    BinaryComparisonView(repository: repository, path: file.path, left: commit.parents.first.map { .revision($0) } ?? .empty, right: .revision(commit.hash)).frame(minHeight: 320)
                } else if let prepared {
                    ChunkDiffView(prepared: prepared, leftTitle: String(localized: "Parent"), rightTitle: commit.shortHash, backgroundStyle: AnyShapeStyle(.windowBackground))
                        .frame(height: min(520, max(160, CGFloat(prepared.previews.reduce(0) { $0 + $1.lines.count }) * 21 + CGFloat(prepared.previews.count) * 30 + 90)))
                } else if let error { Text(error).font(.caption).foregroundStyle(.red).padding(12) }
                else { ProgressView().controlSize(.small).padding(12) }
            } label: {
                HStack(spacing: 9) {
                    StatusBadge(status: file.status).help(statusName)
                    FilePathLabel(path: file.path)
                    Spacer()
                    if let stats { if stats.isBinary { Chip(text: String(localized: "Binary"), tint: .secondary) } else { DiffStat(additions: stats.additions, deletions: stats.deletions) } }
                }.contextMenu {
                    Button("Compare in External Tool…") { store.externalTool(.comparison(commit.parents.first, commit.hash, file.path, nil)) }
                    if let showHistory { Button("Show File History…", action: showHistory) }
                    if let revision = file.status == "D" ? commit.parents.first : commit.hash {
                        if file.status == "D" { Text("Version before deletion · \(String(revision.prefix(8)))") }
                        HistoricalFileMenu(store: store, revision: revision, paths: [file.path])
                    }
                }
            }.disclosureGroupStyle(CommitFileDisclosureStyle())
            .task(id: expanded) {
                guard expanded, diff == nil else { return }
                do {
                    let source = try await repository.commitDiff(commit, path: file.path), path = file.path
                    let value = await Task.detached(priority: .userInitiated) { PreparedPatch.make(source, path: path) }.value
                    guard !Task.isCancelled else { return }; prepared = value; diff = source
                } catch { self.error = error.localizedDescription }
            }
        }.frame(maxWidth: .infinity).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }.id(commit.hash + file.path)
    }
    var statusName: String { localizedFileStatus(file.status.first.map(String.init) ?? "M") }
    var statusColor: Color { switch file.status.first { case "A": .green; case "D": .red; case "R": .purple; default: .blue } }
}

private struct CommitFileDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? Text("Expanded") : Text("Collapsed"))

            if configuration.isExpanded {
                configuration.content.padding(.horizontal, 14)
            }
        }
    }
}

struct CommitFilesTreeView: View {
    @Bindable var store: RepositoryStore
    let repository: GitRepository
    let commit: Commit
    let detail: CommitDetail
    var showHistory: ((String) -> Void)? = nil
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    @State private var showAllFiles = false
    @State private var allPaths: [String]?
    @State private var isLoadingAllFiles = false
    @State private var allFilesError: String?
    @State private var tree = CommitFileTree.empty
    @State private var collapsedFolders: Set<String> = []
    @State private var allFilesCollapsedFolders: Set<String> = []
    @State private var selection: Set<String> = []
    @State private var activePath: String?
    @State private var preparedCache: [String: PreparedPatch] = [:]
    @State private var preparedDiff: PreparedPatch?
    @State private var isLoadingDiff = false
    @State private var diffError: String?
    @State private var historicText = ""
    @State private var isLoadingFile = false
    @State private var fileError: String?

    private var activeCollapsed: Set<String> { showAllFiles ? allFilesCollapsedFolders : collapsedFolders }
    private var rows: [CommitTreeRow] { tree.flattenedRows(collapsed: activeCollapsed) }
    private var activeEntry: CommitFileTreeEntry? { activePath.flatMap { tree.entriesByPath[$0] } }
    private var canExpandAll: Bool { !activeCollapsed.intersection(tree.folderPaths).isEmpty }
    private var canCollapseAll: Bool { !tree.folderPaths.subtracting(activeCollapsed).isEmpty }

    private var rebuildKey: String {
        "\(commit.hash):\(detail.files.count):\(showAllFiles):\(allPaths?.count ?? -1)"
    }

    private var previewKey: String {
        let changedFlag = activeEntry?.isChanged == true ? "1" : "0"
        return "\(commit.hash):\(activePath ?? ""):\(changedFlag)"
    }

    var body: some View {
        PersistentSplitView(name: "commit-files", width: 280, minimum: 200) {
            VStack(spacing: 0) {
                treeHeader
                List(selection: Binding<Set<String>>(get: { selection }, set: { updateSelection($0) })) {
                    ForEach(rows) { row in
                        switch row.kind {
                        case .folder(let folder, let isExpanded):
                            CommitFileTreeFolderRow(
                                store: store,
                                commit: commit,
                                folder: folder,
                                depth: row.depth,
                                isExpanded: isExpanded,
                                showAllFiles: showAllFiles,
                                canExpandAll: canExpandAll,
                                canCollapseAll: canCollapseAll,
                                folderPaths: tree.existingFilePaths(inFolder: folder.path),
                                onToggle: { toggleFolder(folder.path, recursive: $0) },
                                onExpandAll: expandAll,
                                onCollapseAll: collapseAll
                            )
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        case .file(let entry):
                            CommitFileTreeFileRow(
                                store: store,
                                commit: commit,
                                entry: entry,
                                depth: row.depth,
                                hasFolders: tree.hasFolders,
                                isSelected: selection.contains(entry.path),
                                selectedPaths: (selection.contains(entry.path) ? selection.sorted() : [entry.path]).filter { tree.entriesByPath[$0]?.change?.status != "D" },
                                showHistory: showHistory
                            )
                            .tag(entry.path)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        }
                    }
                }
                .listStyle(.plain)
                .pinnedScrollInsets(EdgeInsets(top: 0, leading: 0, bottom: bottomInset, trailing: 0))
                .overlay {
                    if isLoadingAllFiles && rows.isEmpty {
                        ProgressView("Loading files…")
                    } else if let allFilesError, showAllFiles && rows.isEmpty {
                        InspectionErrorView(message: allFilesError)
                    } else if rows.isEmpty {
                        EmptyPane(
                            title: String(localized: "No changed files"),
                            subtitle: String(localized: "This commit does not change any files."),
                            icon: "folder"
                        )
                    }
                }
            }
        } trailing: {
            VStack(spacing: 0) {
                if let entry = activeEntry {
                    if let change = entry.change {
                        FileTitleBar(
                            path: entry.path,
                            subtitle: "\(String(localized: "Parent")) → \(commit.shortHash)",
                            status: change.status
                        ) {
                            if let stats = entry.stats {
                                if stats.isBinary {
                                    Chip(text: String(localized: "Binary"), tint: .secondary)
                                } else {
                                    DiffStat(additions: stats.additions, deletions: stats.deletions, showsBar: false)
                                }
                            }
                        }
                        if entry.stats?.isBinary == true || BinaryComparisonView.isImageCandidate(entry.path) {
                            BinaryComparisonView(
                                repository: repository,
                                path: entry.path,
                                left: commit.parents.first.map { .revision($0) } ?? .empty,
                                right: .revision(commit.hash)
                            )
                            .id(commit.hash + entry.path)
                            .environment(\.repositoryStatusBarInset, bottomInset)
                        } else if let diffError {
                            InspectionErrorView(message: diffError)
                        } else {
                            ChunkDiffView(
                                prepared: preparedDiff,
                                isLoading: isLoadingDiff,
                                leftTitle: String(localized: "Parent"),
                                rightTitle: commit.shortHash
                            )
                            .id(commit.hash + entry.path)
                            .environment(\.repositoryStatusBarInset, bottomInset)
                        }
                    } else {
                        FileTitleBar(path: entry.path, subtitle: commit.shortHash) { EmptyView() }
                        if isLoadingFile {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let fileError {
                            InspectionErrorView(message: fileError)
                        } else {
                            InspectionTextView(
                                text: historicText,
                                scrollInsets: EdgeInsets(top: 0, leading: 0, bottom: bottomInset, trailing: 0)
                            )
                        }
                    }
                } else {
                    EmptyPane(
                        title: detail.files.isEmpty && !showAllFiles ? String(localized: "No changed files") : String(localized: "Select a file"),
                        subtitle: detail.files.isEmpty && !showAllFiles
                            ? String(localized: "This commit does not change any files.")
                            : String(localized: "Pick a file from the tree to review its diff."),
                        icon: "doc.text.magnifyingglass"
                    )
                }
            }
        }
        .padding(.top, topInset)
        .task(id: showAllFiles) {
            guard showAllFiles, allPaths == nil else { return }
            isLoadingAllFiles = true
            allFilesError = nil
            do {
                let fetched = try await repository.fileTree(at: commit.hash)
                guard !Task.isCancelled else { return }
                allPaths = fetched
                isLoadingAllFiles = false
            } catch is CancellationError {
                isLoadingAllFiles = false
            } catch {
                allFilesError = error.localizedDescription
                isLoadingAllFiles = false
            }
        }
        .task(id: rebuildKey) {
            let changes = detail.files
            let stats = detail.statistics
            let paths = showAllFiles ? allPaths : nil
            let built = await Task.detached(priority: .userInitiated) {
                CommitFileTree.build(changes: changes, statistics: stats, allPaths: paths)
            }.value
            guard !Task.isCancelled else { return }
            tree = built
            if showAllFiles && allFilesCollapsedFolders.isEmpty && !built.unmodifiedFolderPaths.isEmpty {
                allFilesCollapsedFolders = built.unmodifiedFolderPaths
            }
            reconcileSelection()
        }
        .task(id: previewKey) {
            await loadSelectedPreview()
        }
    }

    private var treeHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(detail.files.count) files changed")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                DiffStat(additions: detail.additions, deletions: detail.deletions, showsBar: false)
            }
            Spacer(minLength: 4)
            if isLoadingAllFiles {
                ProgressView().controlSize(.mini)
            }
            Menu {
                if tree.hasFolders {
                    Button("Expand All", action: expandAll).disabled(!canExpandAll)
                    Button("Collapse All", action: collapseAll).disabled(!canCollapseAll)
                    Divider()
                }
                Toggle("Show All Files", isOn: $showAllFiles)
            } label: {
                Image(systemName: showAllFiles ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("File tree options")
        }
        .padding(.horizontal, 12)
        .frame(height: Pico.headerHeight)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func updateSelection(_ paths: Set<String>) {
        let valid = paths.intersection(tree.filePaths)
        let added = valid.subtracting(selection)
        selection = valid
        if let firstAdded = rows.compactMap({ row -> String? in
            if case .file(let entry) = row.kind, added.contains(entry.path) { return entry.path }
            return nil
        }).first {
            activePath = firstAdded
        } else if let current = activePath, valid.contains(current) {
            return
        } else {
            activePath = rows.compactMap({ row -> String? in
                if case .file(let entry) = row.kind, valid.contains(entry.path) { return entry.path }
                return nil
            }).first ?? valid.sorted().first
        }
    }

    private func reconcileSelection() {
        selection.formIntersection(tree.filePaths)
        if let current = activePath, tree.entriesByPath[current] != nil {
            if !selection.contains(current) { selection = [current] }
            return
        }
        if let initial = tree.firstChangedFilePath ?? tree.firstFilePath {
            activePath = initial
            selection = [initial]
            let ancestors = tree.ancestorFolders(of: initial)
            collapsedFolders.subtract(ancestors)
            allFilesCollapsedFolders.subtract(ancestors)
        } else {
            activePath = nil
            selection = []
        }
    }

    private func toggleFolder(_ path: String, recursive: Bool) {
        var target = activeCollapsed
        let descendants = tree.descendantFolders[path] ?? []
        if target.contains(path) {
            target.remove(path)
            if recursive { target.subtract(descendants) }
        } else {
            target.insert(path)
            if recursive { target.formUnion(descendants) }
        }
        if showAllFiles { allFilesCollapsedFolders = target }
        else { collapsedFolders = target }
    }

    private func expandAll() {
        if showAllFiles { allFilesCollapsedFolders = [] }
        else { collapsedFolders = [] }
    }

    private func collapseAll() {
        if showAllFiles { allFilesCollapsedFolders = tree.folderPaths }
        else { collapsedFolders = tree.folderPaths }
    }

    private func loadSelectedPreview() async {
        guard let entry = activeEntry else {
            preparedDiff = nil; diffError = nil; isLoadingDiff = false
            historicText = ""; fileError = nil; isLoadingFile = false
            return
        }
        if entry.isChanged {
            historicText = ""; fileError = nil; isLoadingFile = false
            if entry.stats?.isBinary == true || BinaryComparisonView.isImageCandidate(entry.path) {
                preparedDiff = nil; diffError = nil; isLoadingDiff = false
                return
            }
            if let cached = preparedCache[entry.path] {
                preparedDiff = cached; diffError = nil; isLoadingDiff = false
                return
            }
            preparedDiff = nil; diffError = nil; isLoadingDiff = true
            do {
                let raw = try await repository.commitDiff(commit, path: entry.path)
                let path = entry.path
                let built = await Task.detached(priority: .userInitiated) {
                    PreparedPatch.make(raw, path: path)
                }.value
                guard !Task.isCancelled else { return }
                preparedCache[entry.path] = built
                preparedDiff = built
                isLoadingDiff = false
            } catch is CancellationError {
                isLoadingDiff = false
            } catch {
                guard !Task.isCancelled else { return }
                diffError = error.localizedDescription
                isLoadingDiff = false
            }
        } else {
            preparedDiff = nil; diffError = nil; isLoadingDiff = false
            historicText = ""; fileError = nil; isLoadingFile = true
            do {
                let value = try await repository.historicFile(at: commit.hash, path: entry.path)
                guard !Task.isCancelled else { return }
                historicText = value
                isLoadingFile = false
            } catch is CancellationError {
                isLoadingFile = false
            } catch {
                guard !Task.isCancelled else { return }
                fileError = error.localizedDescription
                isLoadingFile = false
            }
        }
    }
}

private struct CommitFileTreeFolderRow: View {
    @Bindable var store: RepositoryStore
    let commit: Commit
    let folder: CommitFileTreeFolder
    let depth: Int
    let isExpanded: Bool
    let showAllFiles: Bool
    let canExpandAll: Bool
    let canCollapseAll: Bool
    let folderPaths: [String]
    let onToggle: (Bool) -> Void
    let onExpandAll: () -> Void
    let onCollapseAll: () -> Void

    private func toggle() {
        onToggle(NSEvent.modifierFlags.contains(.option))
    }

    var body: some View {
        HStack(spacing: 0) {
            if depth > 0 {
                Color.clear.frame(width: WorkingTreeLayout.folderLeadingInset(depth: depth), height: 1)
            }
            Button(action: toggle) {
                HStack(spacing: 0) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: WorkingTreeLayout.chevronWidth, height: 24)
                        .padding(.trailing, WorkingTreeLayout.chevronSpacing)
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "folder.fill" : "folder")
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: 17, height: 17)
                        Text(folder.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if showAllFiles && folder.changedCount > 0 && folder.changedCount < folder.fileCount {
                            HStack(spacing: 0) {
                                Text("\(folder.changedCount)").foregroundStyle(.tint)
                                Text("/\(folder.fileCount)").foregroundStyle(.tertiary)
                            }
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        } else {
                            Text("\(folder.fileCount)")
                                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(folder.name)
            .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
        }
        .frame(height: 24)
        .background(alignment: .leading) {
            WorkingTreeIndentGuides(depth: depth)
        }
        .help(folder.path)
        .contextMenu {
            Button("Expand All", action: onExpandAll).disabled(!canExpandAll)
            Button("Collapse All", action: onCollapseAll).disabled(!canCollapseAll)
            if !folderPaths.isEmpty {
                Divider()
                HistoricalFileMenu(store: store, revision: commit.hash, paths: folderPaths)
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(folder.path, forType: .string)
            }
        }
    }
}

private struct CommitFileTreeFileRow: View {
    @Environment(\.controlActiveState) private var activeState
    @Bindable var store: RepositoryStore
    let commit: Commit
    let entry: CommitFileTreeEntry
    let depth: Int
    let hasFolders: Bool
    let isSelected: Bool
    let selectedPaths: [String]
    var showHistory: ((String) -> Void)? = nil

    private var selectedText: Color {
        Color(nsColor: activeState == .key ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let change = entry.change {
                StatusBadge(status: change.status, selected: isSelected)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? selectedText.opacity(0.85) : .secondary)
                    .frame(width: 17, height: 17)
            }
            FilePathLabel(
                path: entry.path,
                selectedText: isSelected ? selectedText : nil,
                showsParentFolder: false
            )
            Spacer(minLength: 4)
            if let stats = entry.stats {
                if stats.isBinary {
                    Text("Binary")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isSelected ? selectedText.opacity(0.8) : .secondary)
                } else {
                    DiffStat(
                        additions: stats.additions,
                        deletions: stats.deletions,
                        showsBar: false,
                        selectedText: isSelected ? selectedText.opacity(0.9) : nil
                    )
                }
            }
        }
        .frame(height: 24)
        .padding(.leading, WorkingTreeLayout.fileLeadingInset(depth: depth, hasFolders: hasFolders))
        .background(alignment: .leading) {
            WorkingTreeIndentGuides(depth: depth, isSelected: isSelected)
        }
        .contentShape(Rectangle())
        .help(entry.path)
        .contextMenu {
            if let change = entry.change {
                Button("Compare in External Tool…") {
                    store.externalTool(.comparison(commit.parents.first, commit.hash, change.path, nil))
                }
            }
            if let showHistory {
                Button("Show File History…") { showHistory(entry.path) }
            }
            if let change = entry.change, change.status == "D", let parent = commit.parents.first {
                Text("Version before deletion · \(String(parent.prefix(8)))")
                HistoricalFileMenu(store: store, revision: parent, paths: [entry.path])
            } else if !selectedPaths.isEmpty {
                HistoricalFileMenu(store: store, revision: commit.hash, paths: selectedPaths)
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
        }
    }
}
