import GitCore
import SwiftUI

struct HistoryRecoverySheet: View {
    var store: RepositoryStore
    let request: RecoveryRequest
    @State private var expected: HeadPosition?
    @State private var restoreFiles = false
    @State private var branchName = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var title: LocalizedStringResource {
        switch request.action { case .undo(let record, let redo): redo ? "Redo \(record.title)…" : "Undo \(record.title)…"; case .restore: "Restore HEAD"; case .branch: "Recover as Branch" }
    }
    var target: String? {
        switch request.action { case .undo(let record, let redo): (redo ? record.after : record.before).hash; case .restore(let hash), .branch(let hash): hash }
    }
    var requiresClean: Bool { if case .undo(let record, _) = request.action { record.restoresFiles } else { restoreFiles } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title)
            LabeledContent("Current branch", value: store.snapshot?.branch ?? "")
            LabeledContent("Current HEAD", value: expected.map { $0.hash.map { String($0.prefix(12)) } ?? String(localized: "Unborn branch") } ?? String(localized: "Loading…"))
            LabeledContent("Target", value: target.map { String($0.prefix(12)) } ?? String(localized: "Before initial commit"))
            switch request.action {
            case .branch:
                TextField("recovered/my-commit", text: $branchName).textFieldStyle(.roundedBorder)
                Text("Creates a new branch at this commit and keeps the current checkout unchanged.").foregroundStyle(.secondary)
            case .restore:
                Picker("Files", selection: $restoreFiles) {
                    Text("Keep staged and working files").tag(false)
                    Text("Restore tracked files · clean working copy required").tag(true)
                }.pickerStyle(.radioGroup)
                Text("Moves the current branch to the selected commit. The current tip is retained for Undo and Reflog recovery.").foregroundStyle(.secondary)
            case .undo(let record, _):
                Text(record.restoresFiles ? "Restores the branch and tracked files. Commit or stash local edits first." : "Moves the branch tip while preserving the index and every working file. Undoing a commit makes its changes staged again.").foregroundStyle(.secondary)
            }
            if requiresClean && !store.changes.isEmpty { Text("Commit or stash all local changes before this operation.").foregroundStyle(.orange) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(title) { execute() }.keyboardShortcut(.defaultAction)
                    .disabled(expected == nil || store.isBusy || (requiresClean && !store.changes.isEmpty) || store.snapshot?.operation != RepositoryOperation.none || isEmptyBranch)
            }
        }.font(.system(size: 12)).padding(24).frame(width: 550)
            .task { do { expected = try await store.repository?.headPosition() } catch { self.error = error.localizedDescription } }
    }
    var isEmptyBranch: Bool { if case .branch = request.action { branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } else { false } }
    func execute() {
        guard let expected else { return }
        switch request.action {
        case .undo(let record, let redo): store.undoHistory(record, redo: redo)
        case .restore(let hash): store.restoreHistory(hash: hash, expected: expected, restoreFiles: restoreFiles)
        case .branch(let hash): store.recoverBranch(branchName, hash: hash)
        }
        dismiss()
    }
}
