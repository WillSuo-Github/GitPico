import AppKit
import GitCore
import SwiftUI

struct FileHistoryView: View {
    @Bindable var store: RepositoryStore
    let repository: GitRepository
    let path: String
    let revision: String
    @State private var history: FileHistory?
    @State private var selected: String?
    @State private var mode = "Diff"
    @State private var limit = 500
    @State private var allReferences = false
    @State private var showingFiles = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var preview = ""
    @State private var previewError: String?
    @State private var blame: [BlameLine] = []
    @State private var loadingPreview = false
    @State private var ignoreWhitespace = false
    @State private var inspectedCommit: Commit?
    var current: FileRevision? { history?.revisions.first { $0.id == selected } }
    var filtered: [FileRevision] {
        (history?.revisions ?? []).filter { store.search.isEmpty || $0.commit.subject.localizedCaseInsensitiveContains(store.search) || $0.commit.author.localizedCaseInsensitiveContains(store.search) || $0.commit.hash.hasPrefix(store.search) }
    }
    var body: some View {
        PersistentSplitView(name: "fileHistory", width: 320) {
            VStack(spacing: 0) {
                PaneBar(title: path.isEmpty ? "File History" : (path as NSString).lastPathComponent, subtitle: path.isEmpty ? "No file chosen" : "\(history?.revisions.count ?? 0)\(history?.hasMore == true ? "+" : "") commits · " + ((path as NSString).deletingLastPathComponent.nilIfEmpty ?? "repository root"), icon: "doc.text.magnifyingglass") {
                    Toggle("All Refs", isOn: $allReferences).toggleStyle(.checkbox).controlSize(.small).help("Include local branches, remote-tracking branches and tags, following earlier names where discovered.")
                    Button("Choose…") { showingFiles = true }.controlSize(.small).help("Choose another tracked file")
                }
                if let error { InspectionErrorView(message: error) }
                else if isLoading && history == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if path.isEmpty { EmptyPane(title: "File History", subtitle: "Choose a tracked file to inspect its commits, including earlier names.", icon: "doc.text.magnifyingglass") }
                else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { entry in
                                CommitRow(commit: entry.commit, graph: nil, graphWidth: 0, selected: selected == entry.id, fileActions: sourceRevision(entry).map { HistoricalFileMenu(store: store, revision: $0, paths: [entry.path], destination: path) })
                                    .background(selected == entry.id ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { showCommit(entry.commit) }
                                    .onTapGesture { selected = entry.id }
                            }
                            if history?.hasMore == true {
                                Button("Load 500 More Commits") { limit += 500 }.controlSize(.small).padding(14).disabled(isLoading || limit >= 10_000)
                            }
                        }
                    }
                    if filtered.isEmpty { Text("No matching commits").font(.caption).foregroundStyle(.secondary).padding() }
                }
                Divider()
                HStack {
                    Text("From \(String((history?.tip ?? revision).prefix(12)))").help(revision)
                    Spacer()
                    Button { history = nil; limit = 500; Task { await loadHistory() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).disabled(isLoading || path.isEmpty)
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
            }
        } trailing: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if let current { HashChip(hash: current.commit.hash) }
                    if let current {
                        Menu("Actions") {
                            if let source = sourceRevision(current) {
                                if current.isDeleted { Text("Version before deletion · " + String(source.prefix(8))) }
                                HistoricalFileMenu(store: store, revision: source, paths: [current.path], destination: path)
                                Divider()
                            }
                            Button("Show Commit") { showCommit(current.commit) }
                            Button("Copy Commit Hash") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(current.commit.hash, forType: .string) }
                            Button("Copy Path at Revision") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(current.path, forType: .string) }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                    Spacer()
                    if mode == "Diff" { DiffLayoutPicker() }
                    if mode == "Blame" { Toggle("Ignore Whitespace", isOn: $ignoreWhitespace).toggleStyle(.checkbox).font(.caption) }
                    Picker("File view", selection: $mode) { Text("Diff").tag("Diff"); Text("Raw").tag("Raw"); Text("Blame").tag("Blame") }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }.padding(.horizontal, 14).frame(height: Pico.headerHeight).background(.bar).overlay(alignment: .bottom) { Divider() }
                if let current {
                    HStack(spacing: 10) {
                        AuthorAvatar(name: current.commit.author, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(current.commit.subject).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(current.commit.author + " · " + current.commit.date.picoRelative + (current.path != path ? " · as " + current.path : "")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if current.isDeleted { Chip(text: "Deleted here", tint: Pico.deletion) }
                    }.padding(.horizontal, 14).padding(.vertical, 9)
                    Divider()
                    if loadingPreview { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if let previewError { InspectionErrorView(message: previewError) }
                    else if mode == "Diff" { DiffView(text: preview, title: current.path, showsHeader: false) }
                    else if mode == "Blame" { BlameView(lines: blame, inspect: { hash in Task { do { inspectedCommit = try await repository.commit(at: hash) } catch { previewError = error.localizedDescription } } }) }
                    else { InspectionTextView(text: preview) }
                } else { EmptyPane(title: "Select a revision", subtitle: "Pick a commit to see how this file changed, its full contents or line-by-line blame.", icon: "doc.text") }
            }
        }
        .task(id: "\(limit):\(allReferences)") { await loadHistory() }
        .task(id: "\(selected ?? ""):\(mode):\(ignoreWhitespace)") { await loadPreview() }
        .sheet(isPresented: $showingFiles) {
            InspectionFilePicker(repository: repository, revision: history?.tip ?? revision) { store.navigate(.fileHistory($0, history?.tip ?? revision)) }
        }
        .sheet(item: $inspectedCommit) { commit in
            VStack(alignment: .leading, spacing: 14) {
                Text(commit.subject).font(.title3.bold())
                Text("\(commit.author) <\(commit.email)>").font(.callout)
                Text(commit.date.formatted(date: .long, time: .complete)).foregroundStyle(.secondary)
                Text(commit.hash).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                HStack { Spacer(); Button("Close") { inspectedCommit = nil }; Button("Show Commit") { inspectedCommit = nil; showCommit(commit) } }
            }.padding(24).frame(width: 540)
        }
    }
    private func loadHistory() async {
        guard !path.isEmpty else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let value = allReferences ? try await repository.fileHistoryAcrossReferences(path: path, revision: history?.tip ?? revision, limit: limit) : try await repository.fileHistory(path: path, revision: history?.tip ?? revision, limit: limit)
            guard !Task.isCancelled else { return }
            history = value
            if !value.revisions.contains(where: { $0.id == selected }) { selected = value.revisions.first?.id }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func loadPreview() async {
        guard let current else { return }
        preview = ""; blame = []; previewError = nil; loadingPreview = true
        defer { if !Task.isCancelled { loadingPreview = false } }
        do {
            if mode == "Diff" {
                let value = try await repository.fileRevisionDiff(current)
                guard !Task.isCancelled else { return }; preview = value
            } else if current.isDeleted { previewError = "This commit deleted the file. Select an earlier revision to inspect its contents." }
            else if mode == "Blame" {
                let value = try await repository.blame(path: current.path, revision: current.commit.hash, ignoreWhitespace: ignoreWhitespace)
                guard !Task.isCancelled else { return }; blame = value
            } else {
                let value = try await repository.inspectedFile(path: current.path, revision: current.commit.hash)
                guard !Task.isCancelled else { return }; preview = value
            }
        } catch { if !Task.isCancelled { previewError = error.localizedDescription } }
    }
    private func sourceRevision(_ entry: FileRevision) -> String? { entry.isDeleted ? entry.commit.parents.first : entry.commit.hash }
    private func showCommit(_ commit: Commit) { store.navigate(.reference(commit.hash)); store.selectCommit(commit) }
}

struct InspectionFilePicker: View {
    let repository: GitRepository
    let revision: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [String] = []
    @State private var search = ""
    @State private var selected: String?
    @State private var error: String?
    @State private var loading = true
    var matches: [String] { files.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetTitle("Choose File")
            TextField("Search tracked files", text: $search)
            if let error { Text(error).foregroundStyle(.red) }
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                List(selection: $selected) { ForEach(matches, id: \.self) { path in Label(path, systemImage: "doc.text").tag(path) } }.listStyle(.bordered)
                    .overlay { if matches.isEmpty { Text("No tracked files match").foregroundStyle(.secondary) } }
            }
            HStack { Text("\(matches.count) files").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Show History") { if let selected { dismiss(); choose(selected) } }.keyboardShortcut(.defaultAction).disabled(selected == nil)
            }
        }.padding(24).frame(width: 600, height: 480)
        .task { do { files = try await repository.fileTree(at: revision) } catch { self.error = error.localizedDescription }; loading = false }
    }
}

struct BlameView: View {
    let lines: [BlameLine]
    let inspect: (String) -> Void
    @State private var preferences = AppPreferences.shared
    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 0) {
                            HStack(alignment: .top, spacing: 0) {
                                Text(String(line.number)).foregroundStyle(.tertiary).frame(width: 45, alignment: .trailing).padding(.trailing, 12)
                                Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                                Spacer(minLength: 20)
                            }.frame(minWidth: max(300, geometry.size.width - 390), alignment: .leading)
                            Divider()
                            Button { inspect(line.hash) } label: {
                                HStack(spacing: 8) {
                                    AuthorAvatar(name: line.author, size: 16)
                                    Text(String(line.hash.prefix(8))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line.subject).lineLimit(1)
                                        Text("\(line.author) · \(line.date.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }.font(.system(size: 10)).padding(.horizontal, 10).frame(width: 360, alignment: .leading)
                            }.buttonStyle(.plain).help("\(line.subject)\n\(line.author) \(line.email)\n\(line.path):\(line.originalNumber)")
                        }.font(.system(size: preferences.diffFontSize, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 3)
                            .frame(minWidth: geometry.size.width, alignment: .leading).background(line.number.isMultiple(of: 2) ? Color.secondary.opacity(0.035) : .clear)
                    }
                }
            }.defaultScrollAnchor(.topLeading)
        }
    }
}

struct InspectionTextView: View {
    let text: String
    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) { Text(text.isEmpty ? "Empty file" : text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(14).frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading) }.defaultScrollAnchor(.topLeading)
        }
    }
}

struct InspectionErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundStyle(Pico.warning).frame(width: 52, height: 52).background(Pico.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: 420)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
