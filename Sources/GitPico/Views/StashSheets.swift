import GitCore
import SwiftUI

struct StashManagementSheet: View {
    let store: RepositoryStore
    let request: StashRequest
    var body: some View {
        if case .save(let paths, let snapshot) = request.action { StashSaveSheet(store: store, paths: paths, snapshot: snapshot) }
        else { StashActionSheet(store: store, action: request.action) }
    }
}

struct StashSaveSheet: View {
    let store: RepositoryStore
    let paths: [String]
    @State var snapshot: Bool
    @State private var message = ""
    @State private var includeUntracked = true
    @State private var keepIndex = false
    @State private var onlySelected = false
    @State private var selected: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    var candidates: [FileChange] { store.changes.filter { !$0.isConflicted && (includeUntracked || !$0.isUntracked) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(snapshot ? "Create Snapshot" : "Save Stash").font(.title2.bold())
            Text(snapshot ? "Saves your local changes and reapplies them, preserving the staging area." : "Saves local changes temporarily and leaves your working copy clean.").foregroundStyle(.secondary)
            TextField("Stash message", text: $message)
            Toggle("Include Untracked Files", isOn: $includeUntracked)
            Toggle("Keep Staged Changes in Working Copy", isOn: $keepIndex).disabled(snapshot)
            Toggle("Create Snapshot — Keep Local Changes", isOn: $snapshot)
            Toggle("Save Selected Files Only", isOn: $onlySelected)
            if onlySelected {
                List {
                    ForEach(candidates) { file in
                        Toggle(isOn: Binding(get: { selected.contains(file.path) }, set: { if $0 { selected.insert(file.path) } else { selected.remove(file.path) } })) {
                            HStack { StatusBadge(status: file.displayStatus); Text(file.path).lineLimit(1).truncationMode(.middle) }
                        }.toggleStyle(.checkbox)
                    }
                }.listStyle(.bordered).frame(height: 180)
            }
            if store.changes.contains(where: \.isConflicted) { Text("Resolve existing conflicts before saving a stash.").font(.caption).foregroundStyle(.orange) }
            ManagementFooter(title: snapshot ? "Create Snapshot" : "Save Stash", disabled: store.isBusy || store.changes.isEmpty || store.changes.contains(where: \.isConflicted) || (onlySelected && !candidates.contains(where: { selected.contains($0.path) }))) {
                var options = StashSaveOptions()
                options.message = message; options.includeUntracked = includeUntracked; options.keepIndex = keepIndex; options.snapshot = snapshot
                if onlySelected { options.paths = candidates.filter { selected.contains($0.path) }.flatMap { [$0.path, $0.originalPath].compactMap { $0 } } }
                store.saveStash(options); dismiss()
            }
        }.padding(24).frame(width: 560)
        .onAppear { onlySelected = !paths.isEmpty; selected = Set(paths.isEmpty ? candidates.map(\.path) : paths) }
    }
}

struct StashActionSheet: View {
    let store: RepositoryStore
    let action: StashAction
    @State private var restoreIndex = false
    @State private var deleteAfter = false
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    var stash: Stash? {
        switch action {
        case .apply(let stash), .rename(let stash), .delete(let stash), .branch(let stash), .files(let stash, _), .chunk(let stash, _, _, _), .lines(let stash, _, _, _): stash
        default: nil
        }
    }
    var title: String {
        switch action {
        case .apply: "Apply Stash"
        case .rename: "Rename Stash"
        case .delete: "Delete Stash"
        case .clear: "Delete All Stashes"
        case .branch: "Create Branch from Stash"
        case .files: "Apply Selected Files"
        case .chunk: "Apply Stash Chunk"
        case .lines: "Apply Selected Stash Lines"
        case .save: "Save Stash"
        }
    }
    var destructive: Bool { switch action { case .delete, .clear: true; default: false } }
    var disabled: Bool {
        if store.isBusy { return true }
        switch action {
        case .rename: return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .branch: return name.isEmpty || !store.changes.isEmpty
        case .apply, .files, .chunk, .lines: return store.changes.contains(where: \.isConflicted) || store.snapshot?.operation != RepositoryOperation.none
        default: return false
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.bold())
            if let stash {
                LabeledContent("Stash", value: stash.subject).textSelection(.enabled)
                Text(stash.hash).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            switch action {
            case .apply:
                Text("Reapplies the stashed changes to your working copy.").foregroundStyle(.secondary)
                Toggle("Delete Stash After Applying Changes", isOn: $deleteAfter)
                Toggle("Restore Staging Area Status", isOn: $restoreIndex)
                Text("If application fails or conflicts occur, the stash is retained. Resolve and stage conflicts before committing the restored work.").font(.caption).foregroundStyle(.secondary)
            case .rename:
                TextField("New message", text: $name)
                Text("Preserves the stored content and staging state. The renamed entry moves to the top of the stash list.").font(.callout).foregroundStyle(.secondary)
            case .branch:
                TextField("New branch name", text: $name)
                Text("Creates a branch at the stash's original base, restores its changes and index, then removes the stash after success. Requires a clean working copy.").foregroundStyle(.secondary)
            case .delete:
                Text("Removes this stash from the list. Its saved content remains available in Recover Deleted Items.").foregroundStyle(.secondary)
            case .clear(let stashes):
                Text("Removes \(stashes.count) stashes after saving recovery records. Working files are unaffected.").foregroundStyle(.secondary)
            case .files(_, let paths):
                Text("Applies \(paths.count) selected files to the working copy without changing the index or deleting the stash.").foregroundStyle(.secondary)
                ScrollView { Text(paths.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
            case .chunk(_, let file, _, _):
                Text(file.path).font(.callout)
                Text("Applies only this chunk to the working copy. The index and stash are retained. The patch must apply cleanly.").foregroundStyle(.secondary)
            case .lines(_, let file, _, let selection):
                Text(file.path).font(.callout)
                Text("Applies only the \(selection.count) selected changed lines to the working copy. Unselected lines, the index and stash are retained.").foregroundStyle(.secondary)
            case .save: EmptyView()
            }
            ManagementFooter(title: title, disabled: disabled, destructive: destructive) {
                store.executeStashAction(action, restoreIndex: restoreIndex, deleteAfter: deleteAfter, name: name)
                dismiss()
            }
        }.padding(24).frame(width: 560).onAppear { if case .rename(let stash) = action { name = stash.subject } }
    }
}
