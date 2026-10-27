import AppKit
import GitCore
import SwiftUI

struct WorkingCopyView: View {
    @Bindable var store: RepositoryStore
    var files: [WorkingFileEntry] { store.workingList.files }
    var isFiltered: Bool { !store.search.isEmpty || store.workingOnlyConflicts || store.showAllFiles || store.showIgnoredFiles }
    var body: some View {
        PersistentSplitView(name: "working", width: 340) {
            VStack(spacing: 0) {
                WorkingListHeader(store: store)
                if store.snapshot?.operation != RepositoryOperation.none {
                    WorkingOperationPanel(store: store, onlyConflicts: $store.workingOnlyConflicts)
                }
                if store.selectedWorkingFiles.count > 1 {
                    HStack(spacing: 8) {
                        Text("\(store.selectedWorkingFiles.count) selected").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Stage") { store.stageSelectedFiles() }.disabled(store.isBusy || !store.workingTargets().contains { $0.isUnstaged && !$0.isConflicted })
                        Button("Unstage") { store.unstageSelectedFiles() }.disabled(store.isBusy || !store.workingTargets().contains { $0.isStaged && !$0.isConflicted })
                    }.font(.system(size: 11)).controlSize(.small).padding(.horizontal, 12).frame(height: 30)
                        .background(Color.accentColor.opacity(0.07)).overlay(alignment: .bottom) { Divider() }
                }
                List(selection: Binding<Set<String>>(get: { store.selectedWorkingFiles }, set: { store.setWorkingSelection($0) })) {
                    ForEach(files) { file in
                        Group {
                            if let change = file.change { WorkingFileRow(store: store, file: change).picoDrag(store, .workingFiles(store.selectedWorkingFiles.contains(file.path) ? store.selectedWorkingFiles.sorted().filter { path in store.changes.contains { $0.path == path } } : [file.path])) }
                            else { BrowserFileRow(store: store, file: file) }
                        }.tag(file.path).listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    }
                }.listStyle(.plain).disabled(store.isBusy && !store.isBackgroundFetching)
                .overlay {
                    if files.isEmpty && (store.isLoadingWorkingFiles || store.isBusy) { ProgressView("Loading files…") }
                    else if files.isEmpty { EmptyPane(title: isFiltered ? "No matching files" : "Nothing to commit", subtitle: isFiltered ? "Change the file filter or refresh." : "Your working copy matches HEAD. Show All Files to browse the tree.", icon: isFiltered ? "line.3.horizontal.decrease.circle" : "checkmark.seal") }
                }
                if store.snapshot?.operation == RepositoryOperation.none {
                    CommitComposer(store: store)
                }
            }
        } trailing: {
            WorkingDiffView(store: store)
        }.task(id: "\(store.repositoryToken):\(store.showAllFiles):\(store.showIgnoredFiles):\(store.showAssumeUnchanged)") { if store.showAllFiles || store.showIgnoredFiles || store.showAssumeUnchanged { await store.refreshFileBrowser() } }
        .task(id: store.workingFilesInput) { await store.rebuildWorkingList() }

    }
}

/// Branch → upstream, change counts, sorting/visibility options and bulk staging.
struct WorkingListHeader: View {
    @Bindable var store: RepositoryStore
    var upstream: String? { store.snapshot?.references.first(where: \.isCurrent)?.upstream.nilIfEmpty }
    var body: some View {
        let unstagedCount = store.unstaged.count, stagedCount = store.staged.count
        let unstageAll = unstagedCount == 0 && stagedCount > 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Changes").font(.system(size: 13, weight: .semibold))
                if !store.changes.isEmpty { Chip(text: "\(store.changes.count)", tint: .accentColor) }
                Spacer(minLength: 4)
                Menu {
                    Picker("Sort By", selection: $store.workingOrderByStatus) { Text("Status").tag(true); Text("File Name").tag(false) }
                    Divider()
                    Toggle("Show All Files", isOn: $store.showAllFiles)
                    Toggle("Show Ignored Files", isOn: $store.showIgnoredFiles)
                    Toggle("Show Assume-Unchanged Files", isOn: $store.showAssumeUnchanged)
                    Divider()
                    Button("Unstage All") { store.unstage(store.staged) }.disabled(store.isBusy || store.staged.isEmpty)
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Sort and file visibility")
                Button(unstageAll ? "Unstage All" : "Stage All") {
                    if unstageAll { store.unstage(store.staged) }
                    else { store.stage(store.unstaged.filter { !$0.isConflicted }) }
                }
                    .controlSize(.small).disabled(store.isBusy || (!unstageAll && store.unstaged.allSatisfy(\.isConflicted)))
                    .help(unstageAll ? "Unstage every staged file, including files hidden by the filter" : "Stage every changed file, including files hidden by the filter")
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").imageScale(.small)
                Text(store.snapshot?.branch ?? "—").lineLimit(1)
                Image(systemName: "arrow.right").imageScale(.small).foregroundStyle(.tertiary)
                Text(upstream ?? "No upstream").lineLimit(1).foregroundStyle(upstream == nil ? .tertiary : .secondary)
                Spacer(minLength: 4)
                if stagedCount > 0 { Text("\(stagedCount) staged").foregroundStyle(.tint) }
                if unstagedCount > 0 { Text("\(unstagedCount) unstaged") }
            }.font(.system(size: 11)).foregroundStyle(.secondary).truncationMode(.middle)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.bar).overlay(alignment: .bottom) { Divider() }
    }
}

struct WorkingFileRow: View {
    @Environment(\.controlActiveState) private var activeState
    var isSelected: Bool { store.selectedWorkingFiles.contains(file.path) }
    var selectedText: Color { Color(nsColor: activeState == .key ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor) }
    @Bindable var store: RepositoryStore
    let file: FileChange
    var body: some View {
        HStack(spacing: 8) {
            Button { store.toggleWorkingFile(file) } label: {
                Image(systemName: file.isStaged ? (file.isUnstaged ? "minus.square.fill" : "checkmark.square.fill") : "square")
                    .foregroundStyle(isSelected ? selectedText : file.isStaged ? Color.accentColor : Color.secondary)
            }.buttonStyle(.plain).disabled(store.isBusy).help(file.isConflicted ? "Resolve conflict" : file.isStaged && !file.isUnstaged ? "Unstage selected files" : "Stage selected files, including remaining changes")
            .accessibilityLabel(file.isConflicted ? "Resolve conflict in " + file.path : (file.isStaged && !file.isUnstaged ? "Unstage " : "Stage ") + file.path)
            .accessibilityValue(file.isStaged && file.isUnstaged ? "Partially staged" : file.isStaged ? "Staged" : "Unstaged")
            StatusBadge(status: file.displayStatus, selected: isSelected)
            FilePathLabel(path: file.path, selectedText: isSelected ? selectedText : nil)
            Spacer(minLength: 0)
        }.frame(height: 24).contentShape(Rectangle()).help(file.path + " · " + (file.isStaged && file.isUnstaged ? "Staged and unstaged changes" : file.isStaged ? "Staged" : file.displayStatus))
        .contextMenu {
            LFSFileContextMenu(store: store, path: file.path)
            if file.isConflicted { Button("Resolve Conflict…") { store.selectChange(file, staged: false) } }
            else {
                Button("Stage Selected Files") { store.stageSelectedFiles(file.path) }.disabled(store.isBusy || !store.workingTargets(file.path).contains { $0.isUnstaged && !$0.isConflicted })
                Button("Unstage Selected Files") { store.unstageSelectedFiles(file.path) }.disabled(store.isBusy || !store.workingTargets(file.path).contains { $0.isStaged && !$0.isConflicted })
            }
            Divider()
            Button("Discard Local Changes…") { store.discardSelection(file.path) }.disabled(store.isBusy || file.isConflicted)
            Menu("Save Patch as File") {
                Button("Unstaged Changes…") { store.localChange(.export(.unstaged, store.selectedWorkingFiles.contains(file.path) ? store.selectedWorkingFiles.sorted() : [file.path])) }.disabled(!file.isUnstaged)
                Button("Staged Changes…") { store.localChange(.export(.staged, store.selectedWorkingFiles.contains(file.path) ? store.selectedWorkingFiles.sorted() : [file.path])) }.disabled(!file.isStaged)
            }.disabled(store.isBusy || file.isConflicted)
            Divider()
            Button("Stash This File…") { store.stashAction(.save([file.path], false)) }.disabled(file.isConflicted || store.snapshot?.hasHEAD != true)
            Button("Compare in External Tool…") { store.externalTool(.working(file.path, store.stagedDiff)) }.disabled(file.isConflicted || store.isBusy)
            Button("Show File History…") { store.navigate(.fileHistory(file.path, "HEAD")) }.disabled(store.snapshot?.hasHEAD != true || file.isUntracked)
            Button("Open in Default Editor") { if let root = store.snapshot?.root { NSWorkspace.shared.open(root.appendingPathComponent(file.path)) } }
            Button("Reveal in Finder") { if let root = store.snapshot?.root { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(file.path)]) } }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string) }
        }
    }
}

/// Bottom-anchored composer: subject, optional description, identity/options and the primary Commit button.
struct CommitComposer: View {
    @Bindable var store: RepositoryStore
    @State private var workflows = CommitWorkflowLibrary.shared
    @State private var insertion: CommitTemplateInsertion?
    @State private var showBody = false
    @State private var showingAICommit = false
    @FocusState private var subjectFocused: Bool
    var commitTitle: String {
        if store.amend { return "Amend Commit" }
        let count = store.staged.count
        return count == 0 ? "Commit" : "Commit \(count) \(count == 1 ? "File" : "Files")"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    TextField("Summary", text: $store.commitSubject).textFieldStyle(.plain).font(.system(size: 13, weight: .medium)).focused($subjectFocused).accessibilityLabel("Commit summary")
                    if !store.commitSubject.isEmpty { Text("\(store.commitSubject.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(store.commitSubject.count > 72 ? Pico.warning : Color.secondary.opacity(0.6)).help("Summary length; 50–72 characters reads best in logs") }
                    Button { showingAICommit = true } label: { Label("AI", systemImage: "sparkles") }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .help("Generate a commit message or configure your AI tool…")
                        .accessibilityLabel("Generate commit message with AI")
                    Button { showBody.toggle() } label: { Image(systemName: "text.alignleft").foregroundStyle(showBody || !store.commitBody.isEmpty ? Color.accentColor : .secondary) }
                        .buttonStyle(.plain).help(showBody ? "Hide description" : "Add a description")
                }.padding(.horizontal, 10).frame(height: 32)
                if showBody || !store.commitBody.isEmpty {
                    Divider().padding(.horizontal, 8)
                    TextEditor(text: $store.commitBody).font(.system(size: 12)).frame(height: 76).scrollContentBackground(.hidden).padding(.horizontal, 5).padding(.vertical, 4).accessibilityLabel("Commit description")
                        .overlay(alignment: .topLeading) { if store.commitBody.isEmpty { Text("Description").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.vertical, 4).allowsHitTesting(false) } }
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(subjectFocused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor), lineWidth: subjectFocused ? 1.5 : 0.5))
            HStack(spacing: 8) {
                Button { store.navigate(.repositorySettings) } label: {
                    HStack(spacing: 5) {
                        AuthorAvatar(name: store.snapshot?.identity.name.nilIfEmpty ?? "?", size: 18)
                        Text(store.snapshot?.identity.name.nilIfEmpty ?? "No identity").lineLimit(1).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).font(.system(size: 11)).help(identityLine + "\nEdit the commit identity in Repository Settings")
                Spacer(minLength: 4)
                Toggle("Amend", isOn: $store.amend).toggleStyle(.checkbox).font(.system(size: 11)).disabled(store.snapshot?.hasHEAD != true).help("Replace the last commit with the staged changes")
                Menu {
                    Toggle("Add Signed-off-by Trailer", isOn: $store.signOff)
                    Menu("Insert Template") {
                        ForEach(workflows.templates) { template in
                            Button(template.name) { insertion = CommitTemplateInsertion(name: template.name, text: template.text, root: store.snapshot?.root) }
                        }
                        Button("Repository Git Template…") {
                            guard let repository = store.repository else { return }
                            let root = store.snapshot?.root
                            Task {
                                do { let text = try await repository.configuredCommitTemplate(); guard root == store.snapshot?.root else { return }; insertion = CommitTemplateInsertion(name: "Repository Git Template", text: text, root: root) }
                                catch { store.error = error.localizedDescription }
                            }
                        }
                    }
                    Menu("Use Identity") {
                        ForEach(workflows.identities) { identity in Button(identity.label + " · " + identity.email) { store.saveIdentity(name: identity.name, email: identity.email) } }
                    }.disabled(workflows.identities.isEmpty)
                    Button("Edit Identity…") { store.navigate(.repositorySettings) }
                } label: { Image(systemName: store.signOff ? "signature" : "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(store.signOff ? "Signed-off-by will be added" : "Commit options")
                Button(commitTitle, action: store.commit).buttonStyle(.borderedProminent).disabled(!store.canCommit)
                    .help(store.commitUnavailableReason ?? "Commit staged changes (⌘Return)")
            }.controlSize(.regular)
            if let message = statusMessage {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: message.icon).imageScale(.small)
                    Text(message.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if store.commitWarning != nil { Button("Inspect Reflog") { store.navigate(.reflog) }.buttonStyle(.link) }
                }.font(.system(size: 11)).foregroundStyle(message.color)
            }
        }
        .padding(12)
        .background(.bar).overlay(alignment: .top) { Divider() }
        .disabled(store.isBusy && !store.isBackgroundFetching).onChange(of: store.amend) { store.updateAmend() }
        .sheet(item: $insertion) { CommitTemplateInsertionView(store: store, insertion: $0) }
        .sheet(isPresented: $showingAICommit) { AICommitMessageSheet(store: store) }
    }
    var identityLine: String {
        guard let identity = store.snapshot?.identity, !identity.name.isEmpty else { return "No Git identity configured" }
        return identity.name + " <" + identity.email + ">"
    }
    var statusMessage: (text: String, icon: String, color: Color)? {
        if let warning = store.commitWarning { return (warning, "exclamationmark.triangle.fill", Pico.warning) }
        if let feedback = store.commitFeedback { return (feedback, "checkmark.circle.fill", .green) }
        if store.changes.contains(where: \.isConflicted) { return ("Select a conflicted file to resolve it.", "exclamationmark.triangle.fill", Pico.warning) }
        if store.amend { return ("Amend replaces the HEAD commit.", "info.circle", Pico.warning) }
        if let reason = store.commitUnavailableReason { return (reason, "info.circle", .secondary) }
        return nil
    }
}

/// File name emphasized, parent folder dimmed — long paths stay scannable.
struct FilePathLabel: View {
    let path: String
    var selectedText: Color? = nil
    var body: some View {
        let folder = (path as NSString).deletingLastPathComponent
        HStack(spacing: 5) {
            Text((path as NSString).lastPathComponent).foregroundStyle(selectedText ?? .primary).layoutPriority(1)
            if !folder.isEmpty { Text(folder).foregroundStyle(selectedText.map { AnyShapeStyle($0.opacity(0.75)) } ?? AnyShapeStyle(.secondary)).truncationMode(.head) }
        }.font(.system(size: 12)).lineLimit(1)
    }
}

struct WorkingDiffView: View {
    @Bindable var store: RepositoryStore
    var body: some View {
        VStack(spacing: 0) {
            if let file = store.currentChange, file.isConflicted {
                ConflictResolverView(store: store, path: file.path).id(file.path)
            } else if let file = store.currentChange {
                FileTitleBar(path: file.path, subtitle: store.stagedDiff ? "HEAD → Index" : "Index → Working Copy", status: file.displayStatus) {
                    Picker("Diff version", selection: $store.stagedDiff) { Text("Unstaged").tag(false).disabled(!file.isUnstaged && !file.isConflicted); Text("Staged").tag(true).disabled(!file.isStaged) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    DiffLayoutPicker()
                    Menu {
                        Toggle("Ignore Whitespace", isOn: $store.ignoreWhitespace)
                        Picker("Context Lines", selection: $store.diffContext) { ForEach([3, 7, 15, 30], id: \.self) { Text("\($0) lines").tag($0) } }
                    } label: { Image(systemName: store.ignoreWhitespace ? "ellipsis.circle.fill" : "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help(store.ignoreWhitespace ? "Diff options · whitespace ignored (partial staging is disabled)" : "Diff options")
                }
                if store.ignoreWhitespace {
                    Label("Whitespace changes are hidden, so chunk and line staging is paused.", systemImage: "eye.slash").font(.system(size: 11)).foregroundStyle(Pico.warning)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 26).background(Pico.warning.opacity(0.08))
                }
                if let error = store.diffError {
                    VStack(spacing: 12) { Text(error).foregroundStyle(.secondary).textSelection(.enabled); Button("Retry") { store.selectChange(file, staged: store.stagedDiff) } }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let repository = store.repository, BinaryComparisonView.isImageCandidate(file.path) || store.diff.contains("Binary files ") {
                    BinaryComparisonView(repository: repository, path: file.path, originalPath: store.stagedDiff ? file.originalPath : nil,
                        left: store.stagedDiff ? (store.snapshot?.hasHEAD == true ? .revision("HEAD") : .empty) : .index,
                        right: store.stagedDiff ? .index : .workingCopy, version: store.lastUpdated).id(store.repositoryToken.uuidString + file.path)
                } else {
                ChunkDiffView(prepared: store.workingPreparedDiff, isLoading: store.isLoadingDiff, chunkAction: store.ignoreWhitespace ? nil : { store.stageChunk($0) }, lineAction: store.ignoreWhitespace ? nil : { store.stageLines($0) }, actionTitle: store.stagedDiff ? "Unstage Chunk" : "Stage Chunk", leftTitle: store.stagedDiff ? "HEAD" : "Index", rightTitle: store.stagedDiff ? "Index" : "Working Copy", disabled: store.isBusy,
                              discardChunk: store.stagedDiff || store.ignoreWhitespace ? nil : { store.localChange(.chunk(file, store.diff, $0, store.diffContext)) },
                              discardLines: store.stagedDiff || store.ignoreWhitespace ? nil : { store.localChange(.lines(file, store.diff, $0, store.diffContext)) },
                              exportLines: store.ignoreWhitespace ? nil : { store.localChange(.exportLines(file, store.diff, $0, store.stagedDiff, store.diffContext)) }).id(store.repositoryToken.uuidString + file.path)
                }
            } else if let path = store.selectedChange, let repository = store.repository {
                WorkingFilePreview(repository: repository, path: path).id(store.repositoryToken.uuidString + path)
            } else { EmptyPane(title: "Select a file", subtitle: store.changes.isEmpty ? "There are no local changes to review." : "Pick a changed file to review its diff and stage chunks or single lines.", icon: "doc.text.magnifyingglass") }
        }
        .onChange(of: store.stagedDiff) { _, staged in if let file = store.currentChange { store.selectChange(file, staged: staged) } }
        .onChange(of: store.diffContext) { if let file = store.currentChange { store.selectChange(file, staged: store.stagedDiff) } }
        .onChange(of: store.ignoreWhitespace) { if let file = store.currentChange { store.selectChange(file, staged: store.stagedDiff) } }
    }
}

struct PaneHeader: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    var body: some View { PaneBar(title: title, subtitle: subtitle, icon: icon) }
}

struct StatusBadge: View {
    let status: String
    var selected = false
    @Environment(\.controlActiveState) private var activeState
    var selectedText: Color { Color(nsColor: activeState == .key ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor) }
    var color: Color {
        if status == "Untracked" { return .teal }
        switch status.first { case "A": return Pico.addition; case "D": return Pico.deletion; case "R": return .purple; case "C": return Pico.deletion; case "U": return Pico.addition; default: return Pico.modified }
    }
    var body: some View {
        Text(status == "Conflict" ? "!" : status == "Untracked" ? "?" : String(status.prefix(1)))
            .font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundStyle(selected ? selectedText : status == "Conflict" ? .white : color).frame(width: 17, height: 17)
            .background(selected ? AnyShapeStyle(selectedText.opacity(0.18)) : status == "Conflict" ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.16)), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous)).help(status)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
