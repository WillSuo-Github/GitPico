import GitCore
import SwiftUI

struct WorkingOperationPanel: View {
    var store: RepositoryStore
    @Binding var onlyConflicts: Bool
    @State private var confirmAbort = false
    @State private var confirmSkip = false
    var count: Int { store.changes.filter(\.isConflicted).count }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pico.warning)
                    .frame(width: 32, height: 32).background(Pico.warning.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(store.snapshot?.operation.rawValue.capitalized ?? "Integration") in progress").font(.system(size: 13, weight: .semibold))
                    Text(count > 0 ? "\(count) unresolved \(count == 1 ? "conflict" : "conflicts")" : "All conflicts resolved").font(.system(size: 11, weight: .medium)).foregroundStyle(count > 0 ? Pico.deletion : Pico.addition)
                }
                Spacer(minLength: 0)
                if let progress = store.rebaseProgress {
                    Chip(text: "Step \(progress.completed)/\(progress.total)", tint: .secondary)
                }
            }
            if let progress = store.rebaseProgress, progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total)).tint(Pico.warning)
            }
            Text(count > 0 ? "Resolve each file to complete this operation." : store.rebaseProgress?.isEditing == true ? "Stage edits and amend this commit, or Continue without changing it." : "Continue to finish the operation.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Show only conflicted files", isOn: $onlyConflicts).toggleStyle(.checkbox).font(.system(size: 11))
            HStack(spacing: 6) {
                Button("Abort…") { confirmAbort = true }
                if let progress = store.rebaseProgress {
                    if progress.isEditing { Button("Amend…") { store.showingRebaseEdit = true } }
                    Button("Skip…") { confirmSkip = true }
                }
                Spacer()
                Button("Continue", action: store.continueOperation).buttonStyle(.borderedProminent).disabled(count > 0)
            }.controlSize(.small)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Pico.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: Pico.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Pico.corner, style: .continuous).strokeBorder(Pico.warning.opacity(0.25), lineWidth: 0.5)).padding(10).disabled(store.isBusy)
            .confirmationDialog("Abort this operation?", isPresented: $confirmAbort, titleVisibility: .visible) {
                Button("Abort Operation", role: .destructive, action: store.abortOperation)
            } message: { Text("Git will restore the pre-operation state. Edits made while resolving conflicts may be lost.") }
            .confirmationDialog("Skip this rebase commit?", isPresented: $confirmSkip, titleVisibility: .visible) {
                Button("Skip Commit", role: .destructive, action: store.skipRebaseCommit)
            } message: { Text("Drops this replayed commit and its conflict-resolution edits. The original branch tip remains in recovery checkpoints.") }
    }
}
