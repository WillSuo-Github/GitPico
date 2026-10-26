import AppKit
import GitCore
import SwiftUI

struct WorktreeManagementSheet: View {
    var store: RepositoryStore
    let request: WorktreeRequest
    @Environment(\.dismiss) private var dismiss
    @State private var mode = WorktreeBranchMode.new
    @State private var branch = ""
    @State private var revision = "HEAD"
    @State private var path = ""
    @State private var reason = ""
    @State private var openAfter = true
    @State private var reuseEmpty = false
    @State private var plan: WorktreeCreationPlan?
    @State private var reviewed = false
    @State private var loading = false
    @State private var failure: String?
    var title: String {
        switch request.action { case .create: "Add Worktree"; case .move: "Move Worktree"; case .repair: "Repair Worktree"; case .remove: "Remove Worktree"; case .lock: "Lock Worktree"; case .unlock: "Unlock Worktree" }
    }
    var entry: ManagedWorktree? {
        switch request.action { case .create: nil; case .move(let e), .repair(let e), .remove(let e), .lock(let e), .unlock(let e): e }
    }
    var needsPath: Bool { switch request.action { case .create, .move, .repair: true; default: false } }
    var isCreate: Bool { if case .create = request.action { true } else { false } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title, icon: "folder.badge.gearshape")
            if let entry { relatedField("Worktree", entry.path); relatedField("Branch / HEAD", (entry.branch ?? "Detached HEAD") + " · " + String((entry.head ?? "").prefix(12))) }
            if !reviewed {
                if isCreate {
                    Picker("Checkout", selection: $mode) { Text("New branch").tag(WorktreeBranchMode.new); Text("Existing branch").tag(WorktreeBranchMode.existing); Text("Detached HEAD").tag(WorktreeBranchMode.detached) }.pickerStyle(.segmented)
                    if mode != .detached { TextField(mode == .new ? "New branch name" : "Existing local branch", text: $branch).textFieldStyle(.roundedBorder) }
                    if mode != .existing { TextField("Starting revision", text: $revision).textFieldStyle(.roundedBorder) }
                    Toggle("Reuse an existing empty directory", isOn: $reuseEmpty).toggleStyle(.checkbox)
                    Toggle("Open after creating", isOn: $openAfter).toggleStyle(.checkbox)
                }
                if needsPath {
                    HStack { TextField("Absolute worktree folder path", text: $path).textFieldStyle(.roundedBorder); Button("Choose…", action: choosePath) }
                    Text("For Add and Move, choose a new folder outside existing worktrees. Repair requires the relocated folder with its original .git file.").font(.caption).foregroundStyle(.secondary)
                }
                if case .lock = request.action { TextField("Lock reason (optional)", text: $reason).textFieldStyle(.roundedBorder) }
            } else {
                if let plan { relatedField("Checkout", plan.mode == .detached ? "Detached HEAD" : plan.branch); relatedField("Commit", plan.hash) }
                if needsPath { relatedField("Destination", path) }
                if case .lock = request.action { relatedField("Reason", reason.isEmpty ? "No reason" : reason) }
            }
            if case .remove = request.action {
                Text("Remove this linked working directory. All local, untracked and ignored files must be clean. The branch and a backup of Git metadata are retained; the current and main worktrees cannot be removed.").font(.callout).foregroundStyle(.secondary)
            }
            if case .repair = request.action { Text("Reconnect an externally moved linked worktree. GitPico verifies that the selected .git file belongs to this registration.").font(.callout).foregroundStyle(.secondary) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if reviewed { Button("Back") { reviewed = false; plan = nil }; Button(title, action: apply).keyboardShortcut(.defaultAction) }
                else { Button("Review…") { Task { await prepare() } }.keyboardShortcut(.defaultAction) }
            }.disabled(loading || store.isBusy)
        }.padding(24).frame(width: 620).task {
            if case .create(let branch) = request.action, let branch { mode = .existing; self.branch = branch }
            if case .repair(let entry) = request.action { path = entry.path }
        }
    }
    func choosePath() {
        let chooseExisting: Bool
        if case .repair = request.action { chooseExisting = true } else { chooseExisting = reuseEmpty }
        if chooseExisting {
            let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.begin { if $0 == .OK, let url = panel.url { path = url.path } }
        } else {
            let panel = NSSavePanel(); panel.title = title; panel.prompt = "Choose Folder"; panel.nameFieldStringValue = "worktree"
            panel.begin { if $0 == .OK, let url = panel.url { path = url.path } }
        }
    }
    func prepare() async {
        guard let repository = store.repository, request.repositoryToken == store.repositoryToken else { failure = "The repository changed. Close this sheet and retry."; return }
        loading = true; failure = nil; defer { loading = false }
        do {
            if needsPath, !path.hasPrefix("/") { throw GitFailure("Choose an absolute local folder path.") }
            if isCreate { plan = try await repository.previewWorktreeCreation(destination: URL(fileURLWithPath: path), mode: mode, branch: branch, revision: revision, reuseEmptyDirectory: reuseEmpty) }
            if let entry, !(try await repository.managedWorktrees().contains(entry)) { throw GitFailure("The worktree changed. Refresh its list.") }
            guard request.repositoryToken == store.repositoryToken else { throw GitFailure("The repository changed. Reopen this sheet.") }
            reviewed = true
        } catch { failure = error.localizedDescription }
    }
    func apply() {
        guard request.repositoryToken == store.repositoryToken else { failure = "The repository changed. Reopen this sheet."; return }
        if let plan { store.applyWorktreePlan(plan, request: request, openAfter: openAfter) }
        else {
            let action = request.action, destination = URL(fileURLWithPath: path), reason = reason
            store.perform(title + "…") { repository in
                switch action {
                case .move(let entry): try await repository.moveWorktree(entry, to: destination)
                case .repair(let entry): try await repository.repairWorktree(entry, at: destination)
                case .remove(let entry): try await repository.removeWorktree(entry)
                case .lock(let entry): try await repository.setWorktreeLocked(entry, locked: true, reason: reason)
                case .unlock(let entry): try await repository.setWorktreeLocked(entry, locked: false)
                case .create: throw GitFailure("Prepare a worktree preview first.")
                }
            }
        }
        dismiss()
    }
}

struct SubmoduleManagementSheet: View {
    var store: RepositoryStore
    let request: SubmoduleRequest
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var path = ""
    @State private var name = ""
    @State private var branch = ""
    @State private var value = ""
    @State private var recursive = false
    @State private var localTransport = false
    @State private var directoryMode = SubmoduleDirectoryMode.newDirectory
    @State private var plan: SubmodulePlan?
    @State private var addition: SubmoduleAdditionPlan?
    @State private var loading = false
    @State private var failure: String?
    var operation: SubmoduleOperation? { if case .manage(_, let operation) = request.action { operation } else { nil } }
    var title: String { operation?.rawValue ?? "Add Submodule" }
    var reviewed: Bool { plan != nil || addition != nil }
    var supportsRecursion: Bool { operation.map { [.initialize, .update, .fetch, .sync].contains($0) } ?? false }
    var supportsTransport: Bool { operation.map { [.initialize, .update, .fetch, .setURL].contains($0) } ?? true }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title, icon: "shippingbox")
            if case .manage(let entry, _) = request.action {
                relatedField("Submodule", entry.path + " · " + entry.status)
                relatedField("Parent records", entry.recordedHash ?? "No recorded gitlink")
                relatedField("Checked out", entry.head ?? "Not initialized")
            }
            if !reviewed {
                if case .add = request.action {
                    Picker("Directory", selection: $directoryMode) { ForEach(SubmoduleDirectoryMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    TextField("Repository URL", text: $source).textFieldStyle(.roundedBorder)
                    TextField("Relative path in this repository", text: $path).textFieldStyle(.roundedBorder)
                    TextField("Submodule name (optional)", text: $name).textFieldStyle(.roundedBorder)
                    TextField("Tracking branch (optional)", text: $branch).textFieldStyle(.roundedBorder)
                }
                if let operation, [.checkout, .setURL, .move].contains(operation) {
                    TextField(operation == .checkout ? "Commit, tag or branch in the submodule" : operation == .setURL ? "New repository URL" : "New relative path", text: $value).textFieldStyle(.roundedBorder)
                }
                if supportsRecursion { Toggle("Include nested submodules recursively", isOn: $recursive).toggleStyle(.checkbox) }
                if supportsTransport { Toggle("Allow local file transport for this operation", isOn: $localTransport).toggleStyle(.checkbox) }
            } else {
                if let addition { relatedField("Source", addition.source); relatedField("Destination", addition.path); relatedField("Name / branch", addition.name + " · " + (addition.branch.isEmpty ? "Remote default" : addition.branch)) }
                if let plan, !plan.value.isEmpty { relatedField(plan.operation == .checkout ? "Resolved commit" : "New value", plan.value) }
                if supportsRecursion { Text(recursive ? "Includes nested submodules" : "Selected submodule only").font(.caption) }
                if supportsTransport { Text(localTransport ? "Local file transport allowed for this operation" : "Local file transport disabled").font(.caption).foregroundStyle(.secondary) }
            }
            Text(explanation).font(.callout).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if reviewed {
                    Button("Back") { plan = nil; addition = nil }
                    Button("Apply") { if let plan { store.applySubmodulePlan(plan, request: request) }; if let addition { store.addSubmodulePlan(addition, request: request) }; dismiss() }.keyboardShortcut(.defaultAction)
                } else { Button("Review…") { Task { await prepare() } }.keyboardShortcut(.defaultAction) }
            }.disabled(loading || store.isBusy)
        }.padding(24).frame(width: 640)
    }
    var explanation: String {
        switch operation {
        case .remove: "Removes the submodule working directory and stages its removal. Every local, untracked and ignored file must be clean, and its revision must already be recorded in the parent. Git history stays in .git/modules; metadata is backed up. No parent commit is created."
        case .deinitialize: "Clears the clean submodule working directory and its local registration. The parent gitlink and retained Git history remain available for later initialization."
        case .checkout: "Checks out the resolved commit with detached HEAD. Stage the submodule in the parent's Working Copy to record that version."
        case .initialize, .update: "Checks out the exact gitlink recorded by the parent, with detached HEAD. Local changes block the operation. A recursive failure can leave some modules initialized; refresh and retry after resolving the reported error."
        case .setURL, .move: "Updates and stages .gitmodules and any changed gitlink. Existing metadata is backed up. Review these changes in Working Copy and commit them when ready."
        case .sync: "Copies versioned .gitmodules URLs to local Git configuration and initialized module remotes."
        case .fetch: "Downloads Git objects and remote references without changing working files or committing the parent."
        case .repair: "Absorbs an embedded Git directory, or restores a missing .git pointer after verifying retained metadata belongs to this path. Working files are preserved."
        case .forceDeinitialize, .forceRemove: "Backs up the full working directory, index and retained Git storage before clearing local changes. Ignored/untracked files and conflict state are retained in Management Backups. No parent commit is created."
        case .archiveStorage: "Copies retained Git storage into Management Backups, then removes the active module storage directory so the name can be reused. A working directory still using it blocks the operation."
        case .none: "New/empty directories clone from the reviewed URL. Existing/retained repository modes preserve branches and staging without fetching; retained mode populates files from its saved index. Origin URL differences block reuse. Older unstaged/untracked files remain in Management Backups. The parent records HEAD and stages .gitmodules without committing."
        }
    }
    func prepare() async {
        guard let repository = store.repository, request.repositoryToken == store.repositoryToken else { failure = "The repository changed. Close this sheet and retry."; return }
        loading = true; failure = nil; defer { loading = false }
        do {
            switch request.action {
            case .add: addition = try await repository.previewSubmoduleAddition(source: source, path: path, name: name, branch: branch, allowLocalTransport: localTransport, directoryMode: directoryMode)
            case .manage(let entry, let operation): plan = try await repository.previewSubmodule(entry, operation: operation, value: value, recursive: recursive, allowLocalTransport: localTransport)
            }
            guard request.repositoryToken == store.repositoryToken else { plan = nil; addition = nil; throw GitFailure("The repository changed. Reopen this sheet.") }
        } catch { failure = error.localizedDescription }
    }
}
