import AppKit
import GitCore
import SwiftUI

struct WorkingCopyView: View {
    @Bindable var store: RepositoryStore
    var files: [WorkingFileEntry] { store.workingList.files }
    var body: some View {
        PersistentSplitView(name: "working", width: 310) {
            VStack(spacing: 0) {
                PaneHeader(title: store.snapshot?.branch ?? "Working Copy", subtitle: store.snapshot?.references.first(where: \.isCurrent)?.upstream.nilIfEmpty ?? "No Tracking", icon: "arrow.triangle.branch")
                if store.snapshot?.operation != RepositoryOperation.none {
                    WorkingOperationPanel(store: store, onlyConflicts: $store.workingOnlyConflicts)
                } else { CommitComposer(store: store) }
                HStack {
                    Button { store.workingOrderByStatus = true } label: { HStack(spacing: 3) { Text("Status"); if store.workingOrderByStatus { Image(systemName: "chevron.up").font(.system(size: 8)) } } }.frame(width: 65, alignment: .leading)
                    Button { store.workingOrderByStatus = false } label: { HStack(spacing: 3) { Text("Filename"); if !store.workingOrderByStatus { Image(systemName: "chevron.up").font(.system(size: 8)) } } }
                    Spacer()
                    Menu {
                        Toggle("Show All Files", isOn: $store.showAllFiles)
                        Toggle("Show Ignored Files", isOn: $store.showIgnoredFiles)
                        Toggle("Show Assume-Unchanged Files", isOn: $store.showAssumeUnchanged)
                        Divider()
                        Button("Stage All") { store.stage(store.unstaged.filter { !$0.isConflicted }) }.disabled(store.isBusy); Button("Unstage All") { store.unstage(store.staged) }.disabled(store.isBusy) } label: { Image(systemName: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).frame(width: 20)
                }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).frame(height: 28).background(.bar)
                Divider()
                if !store.selectedWorkingFiles.isEmpty {
                    HStack(spacing: 8) {
                        Text("\(store.selectedWorkingFiles.count) selected").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Stage") { store.stageSelectedFiles() }.disabled(store.isBusy || !store.workingTargets().contains { $0.isUnstaged && !$0.isConflicted })
                        Button("Unstage") { store.unstageSelectedFiles() }.disabled(store.isBusy || !store.workingTargets().contains { $0.isStaged && !$0.isConflicted })
                    }.font(.system(size: 11)).controlSize(.small).padding(.horizontal, 10).frame(height: 30).background(.bar)
                }
                List(selection: Binding<Set<String>>(get: { store.selectedWorkingFiles }, set: store.setWorkingSelection)) {
                    ForEach(files) { file in
                        Group {
                            if let change = file.change { WorkingFileRow(store: store, file: change).picoDrag(store, .workingFiles(store.selectedWorkingFiles.contains(file.path) ? store.selectedWorkingFiles.sorted().filter { path in store.changes.contains { $0.path == path } } : [file.path])) }
                            else { BrowserFileRow(store: store, file: file) }
                        }.tag(file.path).listRowInsets(EdgeInsets(top: 3, leading: 9, bottom: 3, trailing: 8))
                    }
                }.listStyle(.plain).disabled(store.isBusy)
                .overlay {
                    if files.isEmpty && (store.isLoadingWorkingFiles || store.isBusy) { ProgressView("Loading files…") }
                    else if files.isEmpty { EmptyPane(title: !store.search.isEmpty || store.workingOnlyConflicts || store.showAllFiles || store.showIgnoredFiles ? "No matching files" : "Working copy is clean", subtitle: !store.search.isEmpty || store.workingOnlyConflicts || store.showAllFiles || store.showIgnoredFiles ? "Change the file filter or refresh." : "Enable Show All Files to browse unchanged files.", icon: "checkmark.circle") }
                }
                Divider()
                HStack { Text("\(files.count) shown"); Spacer(); Text("\(store.staged.count) staged") }
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 26)
            }
        } trailing: {
            WorkingDiffView(store: store)
        }.task(id: "\(store.repositoryToken):\(store.showAllFiles):\(store.showIgnoredFiles):\(store.showAssumeUnchanged)") { if store.showAllFiles || store.showIgnoredFiles || store.showAssumeUnchanged { await store.refreshFileBrowser() } }
        .task(id: store.workingFilesInput) { await store.rebuildWorkingList() }

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
            Image(systemName: "doc.text").foregroundStyle(isSelected ? selectedText.opacity(0.8) : .secondary).font(.system(size: 12))
            Text(file.path).font(.system(size: 12)).foregroundStyle(isSelected ? selectedText : .primary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }.frame(height: 22).contentShape(Rectangle()).help(file.path + " · " + (file.isStaged && file.isUnstaged ? "Staged and unstaged changes" : file.isStaged ? "Staged" : file.displayStatus))
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

struct CommitComposer: View {
    @Bindable var store: RepositoryStore
    @State private var showBody = false
    @State private var showOptions = false
    @FocusState private var subjectFocused: Bool
    var showsDetails: Bool { showOptions || showBody || subjectFocused || !store.commitSubject.isEmpty || store.amend }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsDetails {
            HStack {
                Toggle("Amend", isOn: $store.amend).disabled(store.snapshot?.hasHEAD != true)
                Spacer()
                Toggle("Sign Off", isOn: $store.signOff)
            }.font(.system(size: 10)).toggleStyle(.checkbox)
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                Text("\(store.snapshot?.identity.name ?? "") <\(store.snapshot?.identity.email ?? "")>").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button { store.navigate(.repositorySettings) } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Repository identity")
            }
            }
            HStack(spacing: 5) {
                TextField("Commit Subject", text: $store.commitSubject).textFieldStyle(.roundedBorder).font(.system(size: 12)).focused($subjectFocused)
                Button { showOptions.toggle() } label: { Image(systemName: showOptions ? "chevron.up" : "chevron.down").font(.system(size: 9)) }.buttonStyle(.plain).help("Commit options")
            }
            if showsDetails {
            DisclosureGroup("Extended Description", isExpanded: $showBody) {
                TextEditor(text: $store.commitBody).font(.system(size: 12)).frame(height: 90).scrollContentBackground(.hidden)
                    .padding(4).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack {
                Button("Stage All") { store.stage(store.unstaged) }.disabled(store.unstaged.isEmpty || store.changes.contains(where: \.isConflicted)).help("Stage every changed file, including files hidden by the filter")
                Spacer()
                Button(store.amend ? "Amend Commit" : "Commit", action: store.commit).disabled(!store.canCommit).help(store.commitUnavailableReason ?? "Commit staged changes (⌘Return)")
            }.controlSize(.small)
            HStack {
                Text(store.commitFeedback ?? store.commitUnavailableReason ?? "\(store.staged.count) staged files will be committed.")
                    .font(.caption2).foregroundStyle(store.commitFeedback == nil ? Color.secondary : Color.green)
                Spacer(minLength: 0)
            }
            if let warning = store.commitWarning {
                Text(warning).font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
                Button("Inspect Reflog") { store.navigate(.reflog) }.font(.caption2).buttonStyle(.link)
            }
            if store.amend { Text("Amend replaces the HEAD commit.").font(.caption2).foregroundStyle(.orange) }
            if store.changes.contains(where: \.isConflicted) { Text("Select a conflicted file to resolve it here.").font(.caption2).foregroundStyle(.orange) }
        }.padding(14).disabled(store.isBusy).onChange(of: store.amend) { store.updateAmend() }
    }
}

struct WorkingDiffView: View {
    @Bindable var store: RepositoryStore
    var body: some View {
        VStack(spacing: 0) {
            if let file = store.currentChange, file.isConflicted {
                ConflictResolverView(store: store, path: file.path).id(file.path)
            } else if let file = store.currentChange {
                HStack {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text((file.path as NSString).lastPathComponent).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    DiffLayoutPicker()
                    Picker("Diff version", selection: $store.stagedDiff) { Text("Staged").tag(true).disabled(!file.isStaged); Text("Unstaged").tag(false).disabled(!file.isUnstaged && !file.isConflicted) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                }.font(.system(size: 12)).padding(.horizontal, 14).frame(height: 40).background(.bar)
                Divider()
                if let error = store.diffError {
                    VStack(spacing: 12) { Text(error).foregroundStyle(.secondary).textSelection(.enabled); Button("Retry") { store.selectChange(file, staged: store.stagedDiff) } }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                ChunkDiffView(text: store.diff, isLoading: store.isLoadingDiff, chunkAction: store.ignoreWhitespace ? nil : { store.stageChunk($0) }, lineAction: store.ignoreWhitespace ? nil : { store.stageLines($0) }, actionTitle: store.stagedDiff ? "Unstage Chunk" : "Stage Chunk", leftTitle: store.stagedDiff ? "HEAD" : "Index", rightTitle: store.stagedDiff ? "Index" : "Working Copy", disabled: store.isBusy,
                              discardChunk: store.stagedDiff || store.ignoreWhitespace ? nil : { store.localChange(.chunk(file, store.diff, $0, store.diffContext)) },
                              discardLines: store.stagedDiff || store.ignoreWhitespace ? nil : { store.localChange(.lines(file, store.diff, $0, store.diffContext)) },
                              exportLines: store.ignoreWhitespace ? nil : { store.localChange(.exportLines(file, store.diff, $0, store.stagedDiff, store.diffContext)) }).id(store.repositoryToken.uuidString + file.path + (store.stagedDiff ? ".staged" : ".unstaged"))
                }
                Divider()
                HStack {
                    Toggle(isOn: $store.ignoreWhitespace) { Image(systemName: "textformat") }.toggleStyle(.button).buttonStyle(.borderless).help("Ignore whitespace changes (partial staging is disabled while active)")
                    Spacer()
                    Text(store.stagedDiff ? "HEAD → Index" : "Index → Working Copy").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Context:", selection: $store.diffContext) { ForEach([3, 7, 15, 30], id: \.self) { Text("\($0) lines").tag($0) } }.frame(width: 130)
                }.font(.system(size: 10)).padding(.horizontal, 12).frame(height: 27)
            } else if let path = store.selectedChange, let repository = store.repository {
                WorkingFilePreview(repository: repository, path: path).id(store.repositoryToken.uuidString + path)
            } else { EmptyPane(title: "No file selected", subtitle: "", icon: "doc") }
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
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).lineLimit(1).truncationMode(.middle)
            if let subtitle { Image(systemName: "chevron.right").font(.system(size: 9)); Text(subtitle).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 0)
        }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 40).background(.bar).overlay(alignment: .bottom) { Divider() }
    }
}

struct StatusBadge: View {
    let status: String
    var selected = false
    @Environment(\.controlActiveState) private var activeState
    var selectedText: Color { Color(nsColor: activeState == .key ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor) }
    var color: Color {
        switch status.first { case "A", "U": .green; case "D": .red; case "R": .purple; case "C": .red; default: .blue }
    }
    var body: some View {
        Text(status == "Conflict" ? "!" : status == "Untracked" ? "?" : String(status.prefix(1)))
            .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(selected ? selectedText : color).frame(width: 16, height: 16)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3)).help(status)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
