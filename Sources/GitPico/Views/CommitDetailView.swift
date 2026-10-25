import GitCore
import SwiftUI

struct CommitDetailView: View {
    @Bindable var store: RepositoryStore
    @State private var tree = false
    @State private var metadataExpanded = true
    @State private var expandedFiles: Set<String> = []
    var body: some View {
        VStack(spacing: 0) {
            if let commit = store.selectedCommit {
                HStack {
                    Text(commit.shortHash).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    if store.destination == .reflog {
                        Menu("Recover…") {
                            Button("Create Branch Here…") { store.recoveryRequest = RecoveryRequest(action: .branch(commit.hash)) }
                            Button("Restore HEAD Here…") { store.recoveryRequest = RecoveryRequest(action: .restore(commit.hash)) }
                        }.fixedSize().controlSize(.small)
                    }
                    Menu { Button("Export Files at Revision…") { store.historical(.export, revision: commit.hash) }; Button("Archive Files as ZIP…") { store.historical(.archive, revision: commit.hash) } } label: { Image(systemName: "square.and.arrow.up") }.menuStyle(.borderlessButton).frame(width: 24).disabled(store.isBusy)
                    if !tree { DiffLayoutPicker() }
                    Picker("View", selection: $tree) { Text("Changeset").tag(false); Text("Tree").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 155)
                }.padding(.horizontal, 15).frame(height: 40).background(.bar)
                Divider()
                if tree, let repository = store.repository { HistoricTreeView(store: store, repository: repository, commit: commit, showHistory: { store.navigate(.fileHistory($0, commit.hash)) }).id(commit.hash) }
                else if let detail = store.commitDetail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top) {
                                if metadataExpanded {
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                                    metadataRow("Author", "\(detail.metadata.author) <\(detail.metadata.authorEmail)>")
                                    metadataRow("Author Date", detail.metadata.authorDate.formatted(date: .long, time: .complete))
                                    metadataRow("Committer", "\(detail.metadata.committer) <\(detail.metadata.committerEmail)>")
                                    metadataRow("Committer Date", detail.metadata.committerDate.formatted(date: .long, time: .complete))
                                    GridRow(alignment: .top) {
                                        Text("Refs").foregroundStyle(.secondary).frame(width: 95, alignment: .trailing)
                                        HStack(spacing: 4) {
                                            ForEach(commit.decorations.flatMap { $0.hasPrefix("HEAD -> ") ? ["HEAD", String($0.dropFirst(8))] : [$0] }, id: \.self) { ref in
                                                Text(ref).font(.system(size: 10, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 2).foregroundStyle(.blue).background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                            }
                                        }
                                    }.font(.system(size: 11))
                                    metadataRow("Commit Hash", commit.hash)
                                    metadataRow("Parent Hash", commit.parents.joined(separator: "\n"))
                                    metadataRow("Tree Hash", detail.metadata.tree)
                                }
                                } else { Text(detail.metadata.author).font(.system(size: 12)) }
                                Spacer(minLength: 14)
                                Text(commit.initials).font(.system(size: metadataExpanded ? 28 : 12, weight: .light)).foregroundStyle(.secondary)
                                    .frame(width: metadataExpanded ? 78 : 24, height: metadataExpanded ? 78 : 24).background(.quaternary, in: Circle())
                                Button { metadataExpanded.toggle() } label: { Image(systemName: metadataExpanded ? "chevron.down" : "chevron.left").font(.system(size: 10)) }.buttonStyle(.plain).help("Show or hide commit details")
                            }.padding(16)
                            Divider().padding(.horizontal, 14)
                            Text(detail.message).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            HStack {
                                Button(expandedFiles.count == detail.files.count ? "Collapse All" : "Expand All") { expandedFiles = expandedFiles.count == detail.files.count ? [] : Set(detail.files.map(\.path)) }.buttonStyle(.plain).foregroundStyle(.secondary)
                                Spacer()
                                Text("Showing \(detail.files.count) changed files with \(detail.additions) additions and \(detail.deletions) deletions").foregroundStyle(.secondary)
                            }.font(.system(size: 10)).padding(14)
                            ForEach(detail.files) { file in
                                if let repository = store.repository {
                                    CommitFileDisclosure(store: store, repository: repository, commit: commit, file: file, showHistory: { store.navigate(.fileHistory(file.path, commit.hash)) }, stats: detail.statistics[file.path], expanded: Binding(get: { expandedFiles.contains(file.path) }, set: { if $0 { expandedFiles.insert(file.path) } else { expandedFiles.remove(file.path) } }))
                                }
                            }
                        }
                    }
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else { EmptyPane(title: "No commit selected", subtitle: "Select a commit to inspect its changes.", icon: "clock.arrow.circlepath") }
        }.onChange(of: store.selectedCommit?.id) { expandedFiles = [] }
    }
    func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 95, alignment: .trailing)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11))
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
                if let diff {
                    let patch = PatchDocument(diff)
                    if patch.hunks.isEmpty { Text(diff).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                    if preferences.splitDiff {
                        HStack(spacing: 0) { Text("Parent").frame(maxWidth: .infinity, alignment: .leading); Text(commit.shortHash).frame(maxWidth: .infinity, alignment: .leading) }.font(.system(size: 10)).foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(patch.preview()) { preview in
                        let hunk = preview.hunk
                        Text(hunk.header).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.quaternary.opacity(0.15))
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
                    Text(statusName).font(.system(size: 10)).foregroundStyle(statusColor).frame(width: 50, alignment: .leading)
                    StatusBadge(status: file.status)
                    Text(file.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let stats { Text(stats.isBinary ? "Binary" : "+\(stats.additions) −\(stats.deletions)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                }.padding(.vertical, 9).contextMenu {
                    Button("Compare in External Tool…") { store.externalTool(.comparison(commit.parents.first, commit.hash, file.path, nil)) }
                    if let showHistory { Button("Show File History…", action: showHistory) }
                    if let revision = file.status == "D" ? commit.parents.first : commit.hash {
                        if file.status == "D" { Text("Version before deletion · " + String(revision.prefix(8))) }
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
    var statusName: String { switch file.status.first { case "A": "added"; case "D": "deleted"; case "R": "renamed"; default: "modified" } }
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
