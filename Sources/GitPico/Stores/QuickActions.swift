import Foundation
import GitCore

enum QuickActionTarget {
    case worktree(ManagedWorktree), submodule(ManagedSubmodule), remote(RemoteConfiguration), destination(Destination), file(String), history(String), checkout(Reference), reference(Reference), stash(Stash), commit(Commit), command(QuickCommand)
}
enum QuickCommand: String, CaseIterable {
    case lfs = "Git LFS", gitFlow = "Git Flow", flowFeature = "Start Git Flow Feature", flowRelease = "Start Git Flow Release", flowHotfix = "Start Git Flow Hotfix"
    case moveMain = "Move Main Repository", repairPointers = "Repair Repository Pointers", infrastructureHistory = "Migration / Repair History", managementBackups = "Management Backups", worktree = "Add Worktree", submodule = "Add Submodule", refresh = "Refresh", repositories = "Repositories", quickOpen = "Quick Open", stageAll = "Stage All", unstageAll = "Unstage All", saveStash = "Save Stash", discard = "Discard All Local Changes", recover = "Recover Local Changes", applyPatch = "Apply Patch", branch = "Create Branch", tag = "Create Tag", merge = "Merge", rebase = "Rebase", interactiveRebase = "Interactive Rebase", compare = "Compare Revisions", tools = "External Tool Settings", sessions = "External Tool Sessions", undo = "Undo Git Operation", redo = "Redo Git Operation"
}
struct QuickActionItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let target: QuickActionTarget
}
struct QuickActionSearch {
    static func results(_ items: [QuickActionItem], query: String) -> [QuickActionItem] {
        func fold(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        let query = fold(query.trimmingCharacters(in: .whitespacesAndNewlines)), words = query.split(whereSeparator: \.isWhitespace)
        return items.filter { item in let haystack = fold(item.title + " " + item.subtitle); return words.allSatisfy { haystack.contains($0) } }.sorted { left, right in
            let l = fold(left.title), r = fold(right.title)
            let a = l == query ? 0 : l.hasPrefix(query) ? 1 : 2, b = r == query ? 0 : r.hasPrefix(query) ? 1 : 2
            return a != b ? a < b : left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }
    static func move(_ id: String?, in items: [QuickActionItem], offset: Int) -> String? {
        guard !items.isEmpty else { return nil }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return items.first?.id }
        return items[min(max(index + offset, 0), items.count - 1)].id
    }
}

extension RepositoryStore {
    func quickActionItems(files: [WorkingFileEntry]) -> [QuickActionItem] {
        var result: [QuickActionItem] = []
        for command in QuickCommand.allCases {
            let available: Bool
            switch command {
            case .repositories, .quickOpen, .tools: available = true
            case .flowFeature, .flowRelease, .flowHotfix: available = flowConfiguration != nil && activeFlow == nil && snapshot?.hasHEAD == true && snapshot?.operation == RepositoryOperation.none
            case .stageAll: available = !unstaged.isEmpty && !changes.contains(where: \.isConflicted)
            case .unstageAll: available = !staged.isEmpty
            case .saveStash, .discard: available = !changes.isEmpty && snapshot?.operation == RepositoryOperation.none && !changes.contains(where: \.isConflicted)
            case .worktree, .branch, .tag, .merge, .rebase, .interactiveRebase, .compare: available = snapshot?.hasHEAD == true && snapshot?.operation == RepositoryOperation.none
            case .undo: available = undoAvailability?.undo != nil
            case .redo: available = undoAvailability?.redo != nil
            default: available = repository != nil
            }
            if available { result.append(QuickActionItem(id: "command:" + command.rawValue, title: command.rawValue + "…", subtitle: "Action", icon: "command", target: .command(command))) }
        }
        if repository != nil {
            for destination in [Destination.worktrees, .submodules, .workingCopy, .history, .stashes, .reflog, .branchesReview, .repositorySettings] { result.append(QuickActionItem(id: "destination:" + destination.title, title: "Go to " + destination.title, subtitle: "View", icon: "arrow.right", target: .destination(destination))) }
        }
        for entry in worktrees where !entry.isBare && entry.prunable == nil { result.append(QuickActionItem(id: "worktree:" + entry.id, title: "Open Worktree · " + entry.name, subtitle: entry.path, icon: "folder.badge.gearshape", target: .worktree(entry))) }
        for entry in submodules { result.append(QuickActionItem(id: "submodule:" + entry.id, title: (entry.initialized ? "Open Submodule · " : "Initialize Submodule · ") + entry.path, subtitle: entry.status, icon: "shippingbox", target: .submodule(entry))) }
        for file in files {
            result.append(QuickActionItem(id: "file:" + file.path, title: file.path, subtitle: "Working Copy · " + file.status, icon: "doc", target: .file(file.path)))
            if file.isTracked && snapshot?.hasHEAD == true { result.append(QuickActionItem(id: "file-history:" + file.path, title: "File History · " + file.path, subtitle: "Inspect revisions and blame", icon: "clock", target: .history(file.path))) }
        }
        for ref in snapshot?.references ?? [] {
            result.append(QuickActionItem(id: "ref:" + ref.fullName, title: "History · " + ref.name, subtitle: ref.fullName, icon: "arrow.triangle.branch", target: .reference(ref)))
            if !ref.isCurrent && (ref.isLocal || ref.isRemote) && !ref.name.hasSuffix("/HEAD") { result.append(QuickActionItem(id: "checkout:" + ref.fullName, title: "Checkout · " + ref.name, subtitle: "Switch branch · " + String(ref.hash.prefix(8)), icon: "arrow.turn.down.right", target: .checkout(ref))) }
        }
        for remote in managedRemotes { result.append(QuickActionItem(id: "remote:" + remote.name, title: "Remote · " + remote.name, subtitle: "Edit configuration", icon: "network", target: .remote(remote))) }
        for stash in snapshot?.stashes ?? [] { result.append(QuickActionItem(id: "stash:" + stash.id, title: "Apply Stash · " + stash.subject, subtitle: stash.hash, icon: "tray", target: .stash(stash))) }
        for commit in isHistoryDestination ? visibleCommits : (snapshot?.commits ?? []) { result.append(QuickActionItem(id: "commit:" + commit.hash, title: commit.subject, subtitle: "Commit · " + commit.hash + " · " + commit.author, icon: "clock.arrow.circlepath", target: .commit(commit))) }
        return result
    }
    func runQuickAction(_ item: QuickActionItem, repositoryToken expected: UUID) {
        guard !isBusy, expected == repositoryToken else { if !isBusy { error = "The repository changed. Reopen Quick Actions." }; return }
        switch item.target {
        case .worktree(let entry): openWorktree(entry)
        case .submodule(let entry): if entry.initialized { openSubmodule(entry) } else { manageSubmodule(.manage(entry, .initialize)) }
        case .remote(let remote): manage(.editRemote(remote))
        case .destination(let destination): navigate(destination)
        case .file(let path):
            navigate(.workingCopy); showAllFiles = true; search = ""
            let token = repositoryToken; let ignored = showIgnoredFiles
            guard let repository else { return }
            Task {
                do {
                    let entries = try await repository.workingFiles(includeIgnored: ignored)
                    guard token == repositoryToken else { return }
                    workingFileEntries = entries
                    if let entry = entries.first(where: { $0.path == path }) { if entry.assumeUnchanged { showAssumeUnchanged = true }; selectedWorkingFiles = [path]; selectBrowserFile(entry) }
                    else { error = "The file disappeared. Refresh Quick Actions." }
                } catch { if token == repositoryToken { self.error = error.localizedDescription } }
            }
        case .history(let path): navigate(.fileHistory(path, "HEAD"))
        case .checkout(let ref):
            guard snapshot?.references.contains(where: { $0.fullName == ref.fullName && $0.hash == ref.hash }) == true else { error = "The reference changed. Refresh Quick Actions."; return }
            if ref.isLocal { switchBranch(ref) } else { manage(.createBranch(ref.hash, ref.fullName)) }
        case .reference(let ref): navigate(.reference(ref.fullName))
        case .stash(let stash): stashAction(.apply(stash))
        case .commit(let commit): navigate(.reference(commit.hash)); selectCommit(commit)
        case .command(let command):
            switch command {
            case .lfs: showLFS()
            case .gitFlow: showGitFlow()
            case .flowFeature: manageFlow(.start(.feature))
            case .flowRelease: manageFlow(.start(.release))
            case .flowHotfix: manageFlow(.start(.hotfix))
            case .moveMain: infrastructure(.move)
            case .repairPointers: infrastructure(.repair)
            case .infrastructureHistory: infrastructure(.history)
            case .managementBackups: relatedAdministration(.backups)
            case .worktree: manageWorktree(.create(nil))
            case .submodule: manageSubmodule(.add)
            case .refresh: refresh()
            case .repositories: showingRepositoryLibrary = true
            case .quickOpen: showingQuickOpen = true
            case .stageAll: stage(unstaged.filter { !$0.isConflicted })
            case .unstageAll: unstage(staged)
            case .saveStash: stashAction(.save([], false))
            case .discard: localChange(.discard(changes.map(\.path)))
            case .recover: localChange(.recovery)
            case .applyPatch: choosePatch()
            case .branch: showingBranchSheet = true
            case .tag: manage(.createTag("HEAD"))
            case .merge: integrationRequest = IntegrationRequest(action: .merge)
            case .rebase: integrationRequest = IntegrationRequest(action: .rebase)
            case .interactiveRebase: rebaseRequest = RebaseRequest()
            case .compare: navigate(.comparison("HEAD"))
            case .tools: showingExternalToolSettings = true
            case .sessions: externalTool(.sessions)
            case .undo: if let value = undoAvailability?.undo { recoveryRequest = RecoveryRequest(action: .undo(value, false)) }
            case .redo: if let value = undoAvailability?.redo { recoveryRequest = RecoveryRequest(action: .undo(value, true)) }
            }
        }
    }
}
