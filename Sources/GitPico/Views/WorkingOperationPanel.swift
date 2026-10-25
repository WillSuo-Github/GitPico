import GitCore
import SwiftUI

struct WorkingOperationPanel: View {
    var store: RepositoryStore
    @Binding var onlyConflicts: Bool
    @State private var confirmAbort = false
    @State private var confirmSkip = false
    var count: Int { store.changes.filter(\.isConflicted).count }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.merge").font(.system(size: 28, weight: .semibold)).foregroundStyle(.yellow).padding(.top, 3)
            VStack(alignment: .leading, spacing: 10) {
                Text("\(store.snapshot?.operation.rawValue.capitalized ?? "Integration") in progress").fontWeight(.semibold)
                Text("\(count) unresolved \(count == 1 ? "conflict" : "conflicts")")
                if let progress = store.rebaseProgress {
                    Text("Step \(progress.completed) of \(progress.total)\(progress.isEditing ? " · editing commit" : "")").foregroundStyle(.secondary)
                    if progress.isEditing { Button("Amend Paused Commit…") { store.showingRebaseEdit = true }.controlSize(.small) }
                    Button("Skip This Commit…") { confirmSkip = true }.controlSize(.small)
                }
                Text(count > 0 ? "Resolve each file to complete this operation." : store.rebaseProgress?.isEditing == true ? "Stage edits and amend this commit, or Continue without changing it." : "All conflicts resolved. Continue to finish the operation.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Show only conflicts", isOn: $onlyConflicts).toggleStyle(.checkbox)
                HStack {
                    Button("Abort…") { confirmAbort = true }
                    Spacer()
                    Button("Continue", action: store.continueOperation).disabled(count > 0)
                }.controlSize(.small)
            }.font(.system(size: 11))
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.yellow.opacity(0.18))).padding(12).disabled(store.isBusy)
            .confirmationDialog("Abort this operation?", isPresented: $confirmAbort, titleVisibility: .visible) {
                Button("Abort Operation", role: .destructive, action: store.abortOperation)
            } message: { Text("Git will restore the pre-operation state. Edits made while resolving conflicts may be lost.") }
            .confirmationDialog("Skip this rebase commit?", isPresented: $confirmSkip, titleVisibility: .visible) {
                Button("Skip Commit", role: .destructive, action: store.skipRebaseCommit)
            } message: { Text("Drops this replayed commit and its conflict-resolution edits. The original branch tip remains in recovery checkpoints.") }
    }
}
