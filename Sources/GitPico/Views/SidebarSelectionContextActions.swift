import GitCore
import SwiftUI

struct SidebarSelectionContextActions: View {
    let store: RepositoryStore
    let selection: SidebarContextSelection
    let repositoryToken: UUID
    var body: some View {
        if selection.destinations.count > 1 {
            multipleActions
        } else if let destination = selection.destinations.first {
            switch destination {
            case .reference:
                if let ref = selection.references.first { SidebarReferenceContextActions(store: store, ref: ref) }
            case .workingCopy:
                Button("Discard All Local Changes…") { store.localChange(.discard(store.changes.map(\.path))) }.disabled(store.changes.isEmpty || store.isBusy)
                Button("Recover Local Changes…") { store.localChange(.recovery) }.disabled(store.isBusy)
                Divider()
                Button("Apply Patch…", action: store.choosePatch).disabled(store.isBusy)
                Button("Save Unstaged Patch…") { store.localChange(.export(.unstaged, [])) }.disabled(store.isBusy)
                Button("Save Staged Patch…") { store.localChange(.export(.staged, [])) }.disabled(store.isBusy)
            case .worktree(let path):
                if let entry = store.worktrees.first(where: { $0.path == path }) { WorktreeContextActions(store: store, entry: entry) }
            case .worktrees:
                Button("Add Worktree…") { store.manageWorktree(.create(nil)) }
            case .submodules:
                Button("Add Submodule…") { store.manageSubmodule(.add) }
            default: EmptyView()
            }
        }
    }

    @ViewBuilder private var multipleActions: some View {
        Text("\(selection.destinations.count) selected")
        if selection.onlyReferences {
            if selection.onlyLocalBranches {
                let allPinned = selection.references.allSatisfy { store.organization.pinned.contains($0.fullName) }
                let allArchived = selection.references.allSatisfy { store.organization.archived.contains($0.fullName) }
                let pinTitle: LocalizedStringResource = allPinned ? "Unpin Selected Branches" : "Pin Selected Branches"
                let archiveTitle: LocalizedStringResource = allArchived ? "Unarchive Selected Branches" : "Archive Selected Branches"
                Button(pinTitle) { store.organize(selection.references, pinned: !allPinned, repositoryToken: repositoryToken) }
                    .disabled(store.isBusy || selection.references.count > 256)
                Button(archiveTitle) { store.organize(selection.references, archived: !allArchived, repositoryToken: repositoryToken) }
                    .disabled(store.isBusy || selection.references.count > 256)
            }
            if selection.references.allSatisfy({ $0.isLocal || $0.isTag }) {
                Button("Delete Selected References…", role: .destructive) {
                    store.reviewSidebarReferenceDeletion(selection.references, repositoryToken: repositoryToken)
                }.disabled(store.isBusy || !selection.canDelete || selection.references.count > 256 || selection.references.contains { ref in
                    store.worktrees.contains { $0.branch == ref.fullName }
                })
            }
            Divider()
            Button("Copy Names") { Pico.copy(selection.copiedNames) }
        } else if selection.destinations.allSatisfy({ if case .worktree = $0 { true } else { false } }) {
            let entries = store.worktrees.filter { selection.destinations.contains(.worktree($0.path)) }
            Button("Manage Selected Worktrees…") { store.relatedAdministration(.worktrees(entries)) }
                .disabled(store.isBusy || entries.count != selection.destinations.count)
        } else {
            Text("No shared actions for this selection")
        }
    }
}
