import GitCore
import SwiftUI

struct RelatedAdministrationSheet: View {
    var store: RepositoryStore
    let request: RelatedAdministrationRequest
    var body: some View {
        switch request.action {
        case .backups: RelatedManagementBackupsView(store: store, request: request)
        default: RelatedBatchSheet(store: store, request: request)
        }
    }
}
struct RelatedBatchSheet: View {
    @Bindable var store: RepositoryStore
    let request: RelatedAdministrationRequest
    @Environment(\.dismiss) private var dismiss
    @State private var worktreeOperation = WorktreeBatchOperation.lock
    @State private var submoduleOperation = SubmoduleOperation.initialize
    @State private var value = ""
    @State private var recursive = true
    @State private var localTransport = false
    @State private var plan: RelatedBatchPlan?
    @State private var failure: String?
    @State private var loading = false
    var isWorktree: Bool { if case .worktrees = request.action { true } else { false } }
    var isResume: Bool { if case .resume = request.action { true } else { false } }
    var targets: [String] {
        switch request.action { case .worktrees(let entries): entries.map(\.path); case .submodules(let entries): entries.map(\.path); case .resume(let report): report.items.map(\.path); case .backups: [] }
    }
    var history: RelatedBatchReport? { if case .resume(let report) = request.action { report } else { nil } }
    var completedHistory: Bool { history?.state == "completed" }
    var report: RelatedBatchReport? { store.relatedBatchProgress ?? plan?.report ?? history }
    var needsValue: Bool { isWorktree ? worktreeOperation == .move || worktreeOperation == .lock : [.move, .setURL, .checkout].contains(submoduleOperation) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isResume ? (completedHistory ? "Batch History" : "Resume Batch") : isWorktree ? "Manage Worktrees" : "Manage Submodules", systemImage: "checklist").font(.title2.bold())
            if plan == nil && !isResume {
                if isWorktree { Picker("Operation", selection: $worktreeOperation) { ForEach(WorktreeBatchOperation.allCases, id: \.self) { Text($0.rawValue).tag($0) } } }
                else { Picker("Operation", selection: $submoduleOperation) { ForEach(SubmoduleOperation.allCases, id: \.self) { Text($0.rawValue).tag($0) } } }
                if needsValue { TextField(isWorktree ? (worktreeOperation == .move ? "Absolute destination parent folder" : "Lock reason (optional)") : submoduleOperation == .move ? "Relative destination parent folder" : submoduleOperation == .setURL ? "Repository URL for all selected modules" : "Revision resolved in each submodule", text: $value).textFieldStyle(.roundedBorder) }
                if !isWorktree {
                    Toggle("Include nested submodules when supported", isOn: $recursive).toggleStyle(.checkbox)
                    Toggle("Allow local file transport for this batch", isOn: $localTransport).toggleStyle(.checkbox)
                }
            }
            Text("Each target is validated before execution. The batch stops at the first failure and retains completed results and management backups. Resume reviews remaining targets again; completed items are not replayed.").font(.callout).foregroundStyle(.secondary)
            if let report {
                HStack { Text(report.title).font(.headline); Spacer(); Text(report.state.capitalized).foregroundStyle(.secondary) }
                List(report.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.state == "completed" ? "checkmark.circle.fill" : item.state == "failed" ? "exclamationmark.triangle" : item.state == "running" ? "arrow.triangle.2.circlepath" : "circle").foregroundStyle(item.state == "failed" ? Color.orange : Color.secondary)
                        VStack(alignment: .leading, spacing: 4) { Text(item.path).lineLimit(1).truncationMode(.middle); if !item.value.isEmpty { Text(item.value).font(.caption).foregroundStyle(.secondary).lineLimit(2) }; if let diagnostic = item.diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.red).textSelection(.enabled) } }
                        Spacer(); Text(item.state.capitalized).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }.frame(height: 270)
                if let diagnostic = report.diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled) }
            } else {
                List(targets, id: \.self) { Text($0).lineLimit(1).truncationMode(.middle) }.frame(height: 220)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if loading { ProgressView().controlSize(.small) }; Spacer()
                if store.isBusy { Button("Stop After Current Item") { store.relatedBatchTask?.cancel() }.disabled(store.relatedBatchTask == nil) }
                else {
                    Button(report?.state == "completed" || store.relatedBatchProgress != nil ? "Close" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if let progress = store.relatedBatchProgress {
                        if progress.state != "completed" { Button("Review Remaining…") { Task { await prepare(resuming: progress) } }.disabled(loading) }
                        if plan?.report.state == "prepared" && plan?.report != progress { Button("Continue Batch") { if let plan { store.runRelatedBatch(plan, request: request) } }.disabled(loading) }
                    } else if let plan {
                        Button("Back") { self.plan = nil }; Button("Run Batch") { store.runRelatedBatch(plan, request: request) }.keyboardShortcut(.defaultAction)
                    } else if !completedHistory { Button("Review Batch…") { Task { await prepare() } }.keyboardShortcut(.defaultAction).disabled(loading) }
                }
            }
        }.padding(24).frame(width: 780).interactiveDismissDisabled(store.isBusy).task { if let operation = request.initialWorktreeOperation { worktreeOperation = operation } }
    }
    func prepare(resuming: RelatedBatchReport? = nil) async {
        guard let repository = store.repository, request.repositoryToken == store.repositoryToken else { failure = "The repository changed. Reopen this sheet."; return }
        loading = true; failure = nil; defer { loading = false }
        do {
            if let resuming { plan = try await repository.previewResumeRelatedBatch(resuming); store.relatedBatchProgress = nil }
            else {
                switch request.action {
                case .worktrees(let targets): plan = try await repository.previewWorktreeBatch(targets, operation: worktreeOperation, value: value)
                case .submodules(let targets): plan = try await repository.previewSubmoduleBatch(targets, operation: submoduleOperation, value: value, recursive: recursive, allowLocalTransport: localTransport)
                case .resume(let report): plan = try await repository.previewResumeRelatedBatch(report)
                case .backups: break
                }
            }
            guard request.repositoryToken == store.repositoryToken else { plan = nil; throw GitFailure("The repository changed. Reopen this sheet.") }
        } catch { failure = error.localizedDescription }
    }
}

struct RelatedManagementBackupsView: View {
    @Bindable var store: RepositoryStore
    let request: RelatedAdministrationRequest
    @Environment(\.dismiss) private var dismiss
    @State private var backups: [RelatedManagementBackup] = []
    @State private var legacy: [LegacyManagementBackup] = []
    @State private var legacyChoice: String = ""
    @State private var legacyPath = ""
    @State private var legacyPlan: LegacyManagementRestorePlan?
    @State private var extractionPath = ""
    @State private var extraction: ManagementBackupExtractionPlan?
    @State private var savedModule: SavedModuleRepositoryRecoveryPlan?
    @State private var batches: [RelatedBatchReport] = []
    @State private var selected: UUID?
    @State private var plan: RelatedManagementRestorePlan?
    @State private var failure: String?
    @State private var loading = false
    var chosen: RelatedManagementBackup? { backups.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Management Backups", systemImage: "clock.arrow.circlepath").font(.title2.bold())
            Text("Restore the original directory, staging and Git configuration. Newer files, staging, revisions or configuration block restoration. Current directories are quarantined rather than deleted. Restore multiple operations in reverse order.").font(.callout).foregroundStyle(.secondary)
            if let savedModule {
                relatedField("Saved module repository", savedModule.backup.title)
                relatedField("Recover into", savedModule.destination.path)
                Text("Copies saved Git history, references and staging into an independent repository. Saved working files are included when available. The active module and retained Git directory remain unchanged. No fetch runs.").foregroundStyle(.secondary)
            } else if let extraction {
                relatedField("Backup", extraction.backup.title)
                relatedField("Saved directory", extraction.originalPath)
                relatedField("Extract into", extraction.destination.path)
                Text("Copies the saved files into a new folder and removes Git administrative markers from that copy. The current working tree, index and Git configuration remain intact. Useful when an interrupted operation or newer edits block restoring in place.").foregroundStyle(.secondary)
            } else if let legacyPlan {
                relatedField("Earlier backup", legacyPlan.backup.title)
                relatedField("Saved tree", legacyPlan.tree)
                relatedField("New detached worktree", legacyPlan.destination.path)
                Text("Creates an isolated recovered index snapshot with a recovery commit. The current index, .gitmodules and Git configuration remain intact. Gitlinks are represented by empty module directories; no network initialization is performed.").foregroundStyle(.secondary)
            } else if let plan {
                relatedField("Operation", plan.backup.title)
                relatedField("Recorded", plan.backup.date.formatted())
                Text("Paths included in this restore").font(.headline)
                List(plan.affectedPaths, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }.frame(height: 280)
                Text("The complete saved parent index and the listed configuration files are restored. A stale preview is rejected. No commit or network operation is performed.").font(.caption).foregroundStyle(.secondary)
            } else {
                List(backups, selection: $selected) { backup in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(backup.title).fontWeight(.medium); Spacer(); Text(backup.state.capitalized).font(.caption).foregroundStyle(.secondary) }
                        Text(backup.date.formatted() + " · " + backup.originalPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if let diagnostic = backup.diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                    }.padding(.vertical, 4).tag(backup.id)
                }.frame(height: 250).overlay { if backups.isEmpty && !loading { ContentUnavailableView("No management backups", systemImage: "archivebox") } }
                if chosen != nil {
                    DisclosureGroup("Extract Saved Files into a New Folder") {
                        HStack { TextField("New absolute destination folder", text: $extractionPath).textFieldStyle(.roundedBorder); Button("Review Files…") { Task { await prepareExtraction() } }.disabled(extractionPath.isEmpty) }.padding(.top, 8)
                    }
                }
                if chosen?.kind == "submodule" {
                    HStack { TextField("New absolute saved-repository recovery folder", text: $extractionPath).textFieldStyle(.roundedBorder); Button("Review Saved Git Repository…") { Task { await prepareSavedModule() } }.disabled(extractionPath.isEmpty) }
                }
                Text("Backups keep full directory copies, up to 2 GB / 100,000 entries per directory. They are not automatically removed.").font(.caption).foregroundStyle(.secondary)
                if !legacy.isEmpty {
                    DisclosureGroup("Saved Index Snapshots (\(legacy.count))") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Backup", selection: $legacyChoice) { ForEach(legacy) { Text($0.title).tag($0.id) } }
                            TextField("New absolute recovery folder path", text: $legacyPath).textFieldStyle(.roundedBorder)
                            Text("Earlier records and missing-directory backups can recover their saved index into a new detached worktree for inspection. This preserves the live repository.").font(.caption).foregroundStyle(.secondary)
                            Button("Review Isolated Recovery…") { Task { await prepareLegacy() } }.disabled(legacyPath.isEmpty)
                        }.padding(.top, 8)
                    }
                }
                if !batches.isEmpty {
                    Menu("Batch History / Resume") {
                        ForEach(batches) { report in
                            Button(report.date.formatted(date: .abbreviated, time: .shortened) + " · " + report.title + " · " + report.state) {
                                dismiss(); Task { try? await Task.sleep(for: .milliseconds(180)); store.relatedAdministration(.resume(report)) }
                            }
                        }
                    }
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { if loading { ProgressView().controlSize(.small) }; Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if let savedModule { Button("Back") { self.savedModule = nil }; Button("Recover Saved Repository") { store.recoverSavedModule(savedModule, request: request); dismiss() }.keyboardShortcut(.defaultAction) }
                else if let extraction { Button("Back") { self.extraction = nil }; Button("Extract Saved Files") { store.extractManagementFiles(extraction, request: request); dismiss() }.keyboardShortcut(.defaultAction) }
                else if let legacyPlan { Button("Back") { self.legacyPlan = nil }; Button("Recover into New Worktree") { store.restoreEarlierManagement(legacyPlan, request: request); dismiss() }.keyboardShortcut(.defaultAction) }
                else if let plan { Button("Back") { self.plan = nil }; Button("Restore Backup") { store.restoreManagementBackup(plan, request: request); dismiss() }.keyboardShortcut(.defaultAction) }
                else { Button("Reload") { Task { await load() } }; Button("Review Restore…") { Task { await prepare() } }.keyboardShortcut(.defaultAction).disabled(chosen == nil || chosen?.state == "restored") }
            }.disabled(loading || store.isBusy)
        }.padding(24).frame(width: 800).task { await load() }.onChange(of: selected) { plan = nil }
    }
    func load() async {
        guard let repository = store.repository, request.repositoryToken == store.repositoryToken else { failure = "The repository changed. Reopen Management Backups."; return }
        loading = true; failure = nil; defer { loading = false }
        do { backups = try await repository.relatedManagementBackups(); legacy = try await repository.legacyManagementBackups(); legacyChoice = legacy.first?.id ?? ""; batches = try await repository.relatedBatchReports(); if !backups.contains(where: { $0.id == selected }) { selected = backups.first?.id } }
        catch { failure = error.localizedDescription }
    }
    func prepareSavedModule() async {
        guard let repository = store.repository, let chosen, request.repositoryToken == store.repositoryToken else { return }
        loading = true; failure = nil; defer { loading = false }
        do {
            guard extractionPath.hasPrefix("/") else { throw GitFailure("Choose an absolute new recovery directory.") }
            savedModule = try await repository.previewSavedModuleRepositoryRecovery(chosen, to: URL(fileURLWithPath: extractionPath))
        } catch { failure = error.localizedDescription }
    }
    func prepareExtraction() async {
        guard let repository = store.repository, let chosen, request.repositoryToken == store.repositoryToken else { return }
        loading = true; failure = nil; defer { loading = false }
        do {
            guard extractionPath.hasPrefix("/") else { throw GitFailure("Choose an absolute new destination folder.") }
            extraction = try await repository.previewManagementBackupExtraction(chosen, to: URL(fileURLWithPath: extractionPath))
        } catch { failure = error.localizedDescription }
    }
    func prepareLegacy() async {
        guard let repository = store.repository, let backup = legacy.first(where: { $0.id == legacyChoice }), request.repositoryToken == store.repositoryToken else { return }
        loading = true; failure = nil; defer { loading = false }
        do {
            guard legacyPath.hasPrefix("/") else { throw GitFailure("Choose an absolute new recovery folder.") }
            legacyPlan = try await repository.previewLegacyManagementRestore(backup, to: URL(fileURLWithPath: legacyPath))
        } catch { failure = error.localizedDescription }
    }
    func prepare() async {
        guard let repository = store.repository, let chosen, request.repositoryToken == store.repositoryToken else { return }
        loading = true; failure = nil; defer { loading = false }
        do { plan = try await repository.previewRelatedManagementRestore(chosen) } catch { failure = error.localizedDescription }
    }
}
