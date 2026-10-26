import AppKit
import GitCore
import SwiftUI

struct RepositoryCommands: Commands {
    @Bindable var store: RepositoryStore
    var body: some Commands {
            CommandGroup(replacing: .newItem) {
                if let workspace = store.workspace {
                    Button("New Tab") { workspace.newTab() }.keyboardShortcut("t")
                    Button("Close Tab") {
                        if workspace.windowRouting != nil, let window = NSApp.keyWindow { window.performClose(nil) }
                        else if workspace.windowRouting == nil || workspace.windowRouting?.hasRepositoryWindows == true { _ = workspace.close(workspace.selectedID) }
                    }.keyboardShortcut("w")
                    Divider()
                }
                Button("Repositories", action: store.showRepositories).disabled(store.isBusy || store.isOpeningRepository)
                Button("Quick Open…") { store.showingQuickOpen = true }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(store.isBusy || store.isOpeningRepository)
                Button("Open Repository…", action: store.chooseRepository).keyboardShortcut("o").disabled(store.isBusy || store.isOpeningRepository)
                Button("Clone Git Repository…") { if let workspace = store.workspace { workspace.prepareCreation(clone: true) } else { store.creationRequest = RepositoryCreationRequest(clone: true) } }.keyboardShortcut("o", modifiers: [.command, .option]).disabled(store.isBusy || store.isOpeningRepository)
                Button("New Repository…") { if let workspace = store.workspace { workspace.prepareCreation(clone: false) } else { store.creationRequest = RepositoryCreationRequest(clone: false) } }.disabled(store.isBusy || store.isOpeningRepository)
                Menu("Open Recent") {
                    ForEach(store.recentPaths, id: \.self) { path in
                        Button(store.library.displayName(for: path)) { Task { await store.open(URL(fileURLWithPath: path)) } }
                    }
                }.disabled(store.isBusy || store.isOpeningRepository)
            }
            CommandMenu("Repository") {
                Button("Refresh", action: store.refresh).keyboardShortcut("r").disabled(!store.canUseRepository)
                Divider()
                Group {
                    Button("Fetch") { store.sync(.fetch) }
                    Button("Pull (Fast-forward Only)") { store.sync(.pull) }.disabled(!store.canIntegrate)
                    Button("Push") { store.sync(.push) }.disabled(!store.canIntegrate)
                    Button("Synchronize (Fetch, Pull, Push)", action: store.syncAll).disabled(!store.canSynchronize)
                }.disabled(!store.canUseRepository || store.managedRemotes.isEmpty)
                Menu("Remote Repositories") {
                    Button("Add Remote…") { store.manage(.addRemote) }
                    Divider()
                    Group {
                        Button("Fetch Options…") { store.manage(.fetch(nil)) }
                        Button("Publish / Push To…") { store.manage(.publish(nil, nil, nil, false)) }
                        Button("Delete Remote Reference…") { store.manage(.publish(nil, nil, "refs/heads/main", false)) }
                    }.disabled(store.managedRemotes.isEmpty)
                }.disabled(!store.canUseRepository)
                Divider()
                Menu("Worktrees and Submodules") {
                    Button("Add Worktree…") { store.manageWorktree(.create(nil)) }.disabled(!store.canIntegrate)
                    Button("Add Submodule…") { store.manageSubmodule(.add) }
                    Divider()
                    Button("Show Worktrees") { store.navigate(.worktrees) }
                    Button("Show Submodules") { store.navigate(.submodules) }
                }.disabled(!store.canUseRepository)
                Menu("Management and Recovery") {
                    Button("Move Main Repository…") { store.infrastructure(.move) }
                    Button("Repair Repository Pointers…") { store.infrastructure(.repair) }
                    Button("Migration / Repair History…") { store.infrastructure(.history) }
                    Button("Management Backups…") { store.relatedAdministration(.backups) }
                    Button("Recover Deleted Items…") { store.manage(.recovery) }
                }.disabled(!store.canUseRepository)
                Menu("Extensions") {
                    Button("Git LFS…", action: store.showLFS)
                    GitFlowToolbarMenu(store: store)
                    Divider()
                    Button("External Tool Settings…") { store.showingExternalToolSettings = true }
                    Button("External Tool Sessions…") { store.externalTool(.sessions) }
                }.disabled(!store.canUseRepository)
                Divider()
                Button("Repository Settings") { store.navigate(.repositorySettings) }.disabled(!store.canUseRepository)
                Button("Reveal in Finder") { if let root = store.snapshot?.root { NSWorkspace.shared.activateFileViewerSelecting([root]) } }.disabled(!store.canUseRepository)
            }
            CommandMenu("Branch") {
                Button("New Branch…") { store.showingBranchSheet = true }.keyboardShortcut("b", modifiers: [.command, .shift]).disabled(!store.canIntegrate)
                Button("New Tag…") { store.manage(.createTag("HEAD")) }.disabled(!store.canIntegrate)
                if let ref = store.previewedReference, ref.isLocal {
                    Button("Check Out “\(ref.name)”") { store.switchBranch(ref) }.disabled(store.checkoutUnavailableReason(ref) != nil)
                }
                Divider()
                IntegrationMenuItems(store: store)
            }
            CommandMenu("Commit") {
                Group {
                    Button("Cherry-Pick…") { if let commit = store.selectedCommit { store.integrationRequest = IntegrationRequest(action: .cherryPick, revision: commit.hash) } }.disabled(!store.canIntegrate)
                    Button("Revert…") { if let commit = store.selectedCommit { store.integrationRequest = IntegrationRequest(action: .revert, revision: commit.hash) } }.disabled(!store.canIntegrate)
                    Button("Create Branch Here…") { if let commit = store.selectedCommit { store.manage(.createBranch(commit.hash, nil)) } }
                    Button("Restore HEAD Here…") { if let commit = store.selectedCommit { store.recoveryRequest = RecoveryRequest(action: .restore(commit.hash)) } }.disabled(!store.canIntegrate)
                    Divider()
                    Menu("Export") {
                        Button("Original Files…") { if let commit = store.selectedCommit { store.historical(.export, revision: commit.hash) } }
                        Button("ZIP Archive…") { if let commit = store.selectedCommit { store.historical(.archive, revision: commit.hash) } }
                        Button("Patch…") { if let commit = store.selectedCommit { store.localChange(.export(.commit(commit.hash), [])) } }
                    }
                }.disabled(!store.canUseRepository || store.selectedCommit == nil)
            }
            CommandMenu("Working Copy") {
                Group {
                Button("Commit Staged Changes", action: store.commit).keyboardShortcut(.return, modifiers: .command).disabled(!store.canCommit || store.destination != .workingCopy)
                Button("Stage Selected Files") { store.stageSelectedFiles() }.disabled(!store.workingTargets().contains { $0.isUnstaged && !$0.isConflicted })
                Button("Unstage Selected Files") { store.unstageSelectedFiles() }.disabled(!store.workingTargets().contains { $0.isStaged && !$0.isConflicted })
                Divider()
                Toggle("Show All Files", isOn: $store.showAllFiles).keyboardShortcut("m", modifiers: [.command, .control])
                Toggle("Show Ignored Files", isOn: $store.showIgnoredFiles).keyboardShortcut("i", modifiers: [.command, .control])
                Toggle("Show Assume-Unchanged Files", isOn: $store.showAssumeUnchanged).keyboardShortcut("u", modifiers: [.command, .control])
                Divider()
                Button("Discard Selected Local Changes…") { store.discardSelection() }.keyboardShortcut(.delete, modifiers: [.command, .shift]).disabled(store.isBusy || store.selectedWorkingFiles.isEmpty)
                Button("Discard All Local Changes…") { store.localChange(.discard(store.changes.map(\.path))) }.disabled(store.isBusy || store.changes.isEmpty)
                Button("Recover Local Changes…") { store.localChange(.recovery) }.disabled(store.isBusy || store.snapshot == nil)
                Divider()
                Button("Apply Patch…", action: store.choosePatch).disabled(store.isBusy || store.snapshot == nil)
                Menu("Save Patch as File") {
                    Button("Unstaged Changes…") { store.localChange(.export(.unstaged, [])) }
                    Button("Staged Changes…") { store.localChange(.export(.staged, [])) }
                    Button("Selected Commit…") { if let commit = store.selectedCommit { store.localChange(.export(.commit(commit.hash), [])) } }.disabled(store.selectedCommit == nil)
                }.disabled(store.isBusy || store.snapshot == nil)
                Divider()
                Button("Save Stash…") { store.stashAction(.save([], false)) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(store.changes.isEmpty)
                Button("Create Snapshot…") { store.stashAction(.save([], true)) }.disabled(store.changes.isEmpty)
                Button("Apply Stash…") { if let stash = store.selectedStash ?? store.snapshot?.stashes.first { store.stashAction(.apply(stash)) } }.disabled(store.snapshot?.stashes.isEmpty != false)
                }.disabled(!store.canUseRepository)
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { store.searchFocusRequest = UUID() }.keyboardShortcut("f")
                    .disabled(!store.canUseRepository)
            }
            CommandGroup(after: .undoRedo) {
                Divider()
                Button("Undo Git \(store.undoAvailability?.undo?.title ?? "Operation")…") {
                    if let record = store.undoAvailability?.undo { store.recoveryRequest = RecoveryRequest(action: .undo(record, false)) }
                }.keyboardShortcut("z", modifiers: [.command, .option]).disabled(store.undoAvailability?.undo == nil || !store.canUseRepository)
                Button("Redo Git \(store.undoAvailability?.redo?.title ?? "Operation")…") {
                    if let record = store.undoAvailability?.redo { store.recoveryRequest = RecoveryRequest(action: .undo(record, true)) }
                }.keyboardShortcut("z", modifiers: [.command, .option, .shift]).disabled(store.undoAvailability?.redo == nil || !store.canUseRepository)
            }
            CommandMenu("Navigate") {
                if let workspace = store.workspace {
                    Button("Next Tab") { workspace.cycle(1) }.keyboardShortcut(.tab, modifiers: .control)
                    Button("Previous Tab") { workspace.cycle(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
                    Divider()
                }
                Button("Quick Actions…") { store.searchActionsRequest = UUID() }.keyboardShortcut("a", modifiers: [.command, .shift]).disabled(!store.canUseRepository)
                Button("External Tool Settings…") { store.showingExternalToolSettings = true }
                Button("External Tool Sessions…") { store.externalTool(.sessions) }.disabled(!store.canUseRepository)
                Divider()
                Button("Back", action: store.goBack).keyboardShortcut("[").disabled(store.isBusy || store.backStack.isEmpty)
                Button("Forward", action: store.goForward).keyboardShortcut("]").disabled(store.isBusy || store.forwardStack.isEmpty)
                Divider()
                Button("File History…") { store.navigate(.fileHistory("", "HEAD")) }.disabled(!store.canBrowseHistory)
                Button("Compare Revisions…") { store.navigate(.comparison("HEAD")) }.disabled(!store.canBrowseHistory)
                Divider()
                Group {
                Button("Working Copy") { store.navigate(.workingCopy) }.keyboardShortcut("1")
                Button("History") { store.navigate(.history) }.keyboardShortcut("2")
                Button("Worktrees") { store.navigate(.worktrees) }
                Button("Submodules") { store.navigate(.submodules) }
                Button("Reflog") { store.navigate(.reflog) }.keyboardShortcut("6")
                Button("Stashes") { store.navigate(.stashes) }.keyboardShortcut("3")
                Button("Branches Review") { store.navigate(.branchesReview) }.keyboardShortcut("4")
                Button("Repository Settings") { store.navigate(.repositorySettings) }.keyboardShortcut("5")
                }.disabled(!store.canUseRepository)
            }

    }
}
