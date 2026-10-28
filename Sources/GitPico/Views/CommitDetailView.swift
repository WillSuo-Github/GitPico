import GitCore
import SwiftUI

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
    var body: some View {
        VStack(spacing: 0) {
            if let commit = store.selectedCommit {
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
                    if !tree { DiffLayoutPicker() }
                    Picker("View", selection: $tree) { Text("Changes").tag(false); Text("Files").tag(true) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }.padding(.horizontal, 14).frame(height: Pico.headerHeight).background(.bar).overlay(alignment: .bottom) { Divider() }
                if tree, let repository = store.repository { HistoricTreeView(store: store, repository: repository, commit: commit, showHistory: { store.navigate(.fileHistory($0, commit.hash)) }).id(commit.hash) }
                else if let detail = store.commitDetail {
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
                            ChangedFilesHeader(count: detail.files.count, additions: detail.additions, deletions: detail.deletions, allExpanded: !detail.files.isEmpty && expandedFiles.count == detail.files.count) {
                                expandedFiles = expandedFiles.count == detail.files.count ? [] : Set(detail.files.map(\.path))
                            }
                            if let repository = store.repository {
                                ForEach(detail.files) { file in
                                    CommitFileDisclosure(store: store, repository: repository, commit: commit, file: file, showHistory: { store.navigate(.fileHistory(file.path, commit.hash)) }, stats: detail.statistics[file.path], expanded: Binding(get: { expandedFiles.contains(file.path) }, set: { if $0 { expandedFiles.insert(file.path) } else { expandedFiles.remove(file.path) } }))
                                }
                            }
                        }
                    }
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else { EmptyPane(title: String(localized: "Select a commit"), subtitle: String(localized: "Pick a commit to read its message and review every changed file."), icon: "clock.arrow.circlepath") }
        }.onChange(of: store.selectedCommit?.id) { expandedFiles = [] }
        .sheet(item: $parentComparison) { request in
            if let repository = store.repository {
                VStack(spacing: 12) {
                    HStack { SheetTitle("Merge Parent Comparison", icon: "arrow.triangle.merge"); Spacer(); Button("Close") { parentComparison = nil }.keyboardShortcut(.cancelAction) }
                    RevisionComparisonView(store: store, repository: repository, initialLeft: request.parent, initialRight: request.commit)
                }.padding(20).frame(width: 1060, height: 720)
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
        .background(.bar.opacity(0.6)).overlay(alignment: .top) { Divider() }
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
    @State private var error: String?
    @State private var contentWidth: CGFloat = 0
    @State private var preferences = AppPreferences.shared
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            DisclosureGroup(isExpanded: $expanded) {
                if stats?.isBinary == true || BinaryComparisonView.isImageCandidate(file.path) {
                    BinaryComparisonView(repository: repository, path: file.path, left: commit.parents.first.map { .revision($0) } ?? .empty, right: .revision(commit.hash)).frame(minHeight: 320)
                } else if let diff {
                    let patch = PatchDocument(diff)
                    if patch.hunks.isEmpty { Text(diff).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                    if preferences.splitDiff {
                        HStack(spacing: 0) { Text("Parent").frame(maxWidth: .infinity, alignment: .leading); Text(commit.shortHash).frame(maxWidth: .infinity, alignment: .leading) }.font(.system(size: 10)).foregroundStyle(.secondary).padding(8).environment(\.layoutDirection, .leftToRight)
                    }
                    ForEach(patch.preview()) { preview in
                        let hunk = preview.hunk
                        Text(hunk.header).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.accentColor.opacity(0.85)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6).background(Color.accentColor.opacity(0.06))
                        if preferences.splitDiff {
                            SplitDiffView(lines: preview.lines, fontSize: preferences.diffFontSize, minimumWidth: max(0, contentWidth - 28))
                        } else { ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(preview.lines) { line in DiffLineView(line: line, fontSize: 11).frame(minWidth: max(0, contentWidth - 28), alignment: .leading) }
                            }
                        } }
                    }
                } else if let error { Text(error).font(.caption).foregroundStyle(.red).padding(12) }
                else { ProgressView().controlSize(.small).padding(12) }
            } label: {
                HStack(spacing: 9) {
                    StatusBadge(status: file.status).help(statusName)
                    FilePathLabel(path: file.path)
                    Spacer()
                    if let stats { if stats.isBinary { Chip(text: String(localized: "Binary"), tint: .secondary) } else { DiffStat(additions: stats.additions, deletions: stats.deletions) } }
                }.padding(.vertical, 8).contentShape(Rectangle()).contextMenu {
                    Button("Compare in External Tool…") { store.externalTool(.comparison(commit.parents.first, commit.hash, file.path, nil)) }
                    if let showHistory { Button("Show File History…", action: showHistory) }
                    if let revision = file.status == "D" ? commit.parents.first : commit.hash {
                        if file.status == "D" { Text("Version before deletion · \(String(revision.prefix(8)))") }
                        HistoricalFileMenu(store: store, revision: revision, paths: [file.path])
                    }
                }
            }.padding(.horizontal, 14)
            .task(id: expanded) {
                guard expanded, diff == nil else { return }
                do { diff = try await repository.commitDiff(commit, path: file.path) } catch { self.error = error.localizedDescription }
            }
        }.frame(maxWidth: .infinity).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }.id(commit.hash + file.path)
    }
    var statusName: String { localizedFileStatus(file.status.first.map(String.init) ?? "M") }
    var statusColor: Color { switch file.status.first { case "A": .green; case "D": .red; case "R": .purple; default: .blue } }
}

struct HistoricTreeView: View {
    @Bindable var store: RepositoryStore
    let repository: GitRepository
    let commit: Commit
    var showHistory: ((String) -> Void)? = nil
    @State private var files: [String] = []
    @State private var selection: Set<String> = []
    var selected: String? { selection.sorted().first }
    @State private var text = ""
    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                OutlineGroup(HistoricFileNode.build(files), children: \.children) { node in
                    Label(node.name, systemImage: node.children == nil ? "doc" : "folder").font(.system(size: 11)).tag(node.path).contextMenu {
                        if node.children == nil, let showHistory { Button("Show File History…") { showHistory(node.path) } }
                        HistoricalFileMenu(store: store, revision: commit.hash, paths: selection.contains(node.path) ? selection.sorted() : [node.path])
                    }
                }
            }.listStyle(.plain).frame(height: 180)
            Divider()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(14).frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading) }.defaultScrollAnchor(.topLeading)
            }
        }
        .task { do { files = try await repository.fileTree(at: commit.hash) } catch { text = error.localizedDescription } }
        .task(id: selected) {
            guard let selected else { text = ""; return }
            text = ""
            do { let value = try await repository.historicFile(at: commit.hash, path: selected); guard !Task.isCancelled else { return }; text = value } catch { if !Task.isCancelled { text = error.localizedDescription } }
        }
    }
}

private struct HistoricFileNode: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let children: [HistoricFileNode]?
    static func build(_ paths: [String], prefix: String = "") -> [HistoricFileNode] {
        let groups = Dictionary(grouping: paths) { String($0.dropFirst(prefix.count).split(separator: "/").first ?? "") }
        return groups.keys.sorted().map { name in
            let path = prefix + name
            let values = groups[name] ?? []
            let isFile = values.contains(path)
            return HistoricFileNode(path: path, name: name, children: isFile ? nil : build(values, prefix: path + "/"))
        }
    }
}
