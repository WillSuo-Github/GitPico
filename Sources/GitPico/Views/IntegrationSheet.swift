import GitCore
import SwiftUI

struct IntegrationSheet: View {
    var store: RepositoryStore
    let request: IntegrationRequest
    @State private var revision = ""
    @State private var commit: Commit?
    @State private var mainline = 1
    @State private var loadError: String?
    @State private var expectedHead: HeadPosition?
    @Environment(\.dismiss) private var dismiss
    var targets: [Reference] { (store.snapshot?.references ?? []).filter { !$0.isCurrent && !$0.name.hasSuffix("/HEAD") } }
    var title: LocalizedStringResource { "\(request.action.title)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetTitle(title)
            LabeledContent("Current branch", value: store.snapshot?.branch ?? "")
            if request.revision != nil || request.action == .cherryPick || request.action == .revert {
                LabeledContent("Commit", value: request.revision ?? "") .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                if let commit { Text(commit.subject).font(.callout) }
                if request.action == .revert, let commit, commit.parents.count > 1 {
                    Picker("Mainline parent", selection: $mainline) {
                        ForEach(Array(commit.parents.enumerated()), id: \.offset) { index, hash in Text("Parent \(index + 1) · \(hash.prefix(12))").tag(index + 1) }
                    }
                    Text("Revert reverses the merge's changes relative to this parent.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Picker(request.action == .merge ? "Merge branch" : "Rebase onto", selection: $revision) {
                    Text("Choose a branch…").tag("")
                    ForEach(targets) { ref in Text(ref.name).tag(ref.fullName) }
                }
                if let ref = targets.first(where: { $0.fullName == revision }) { LabeledContent("Target commit", value: String(ref.hash.prefix(12))).font(.system(size: 11, design: .monospaced)) }
            }
            if let loadError { Text(loadError).foregroundStyle(.red).font(.caption) }
            Text(request.action == .revert ? "Creates a new commit reversing these changes and preserves existing history. If conflicts occur, resolve them and use Continue or Abort." : request.action == .rebase ? "Rebase replays the current branch's commits onto the selected branch and changes their hashes." : "The operation updates the current branch. If conflicts occur, resolve them and use Continue or Abort.")
                .font(.callout).foregroundStyle(.secondary)
            if !store.changes.isEmpty { Label(AppPreferences.shared.offerAutomaticStash ? "You will be offered to stash local changes before continuing." : "Commit or stash local changes first.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(title) { store.integrate(request, revision: request.revision ?? revision, mainline: request.action == .revert && (commit?.parents.count ?? 0) > 1 ? mainline : nil, expectedHead: expectedHead); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(store.isBusy || (!store.changes.isEmpty && !AppPreferences.shared.offerAutomaticStash) || (request.revision == nil && revision.isEmpty) || store.snapshot?.operation != RepositoryOperation.none || expectedHead == nil || (request.revision != nil && commit == nil))
            }
        }.padding(24).frame(width: 520).onAppear { revision = request.revision ?? targets.first?.fullName ?? "" }
        .task {
            guard let repository = store.repository else { return }
            do {
                if let captured = request.expectedHead { expectedHead = captured }
                else { expectedHead = try await repository.headPosition() }
                if let revision = request.revision { commit = try await repository.commit(at: revision) }
            } catch { loadError = error.localizedDescription }
        }
    }
}

struct OperationBanner: View {
    var store: RepositoryStore
    @State private var confirmAbort = false
    var body: some View {
        if let operation = store.snapshot?.operation, operation != .none {
            NoticeBanner(icon: "arrow.triangle.merge", title: "\(operation.inProgressTitle)", message: store.changes.contains(where: \.isConflicted) ? String(localized: "Resolve and stage conflicts in Working Copy, then continue.") : String(localized: "All conflicts are resolved. Continue to finish.")) {
                Button("Show Conflicts") { store.navigate(.workingCopy) }.disabled(store.destination == .workingCopy)
                Button("Abort…") { confirmAbort = true }
                Button("Continue", action: store.continueOperation).buttonStyle(.borderedProminent).disabled(store.changes.contains(where: \.isConflicted))
            }.disabled(store.isBusy)
                .confirmationDialog("Abort this operation?", isPresented: $confirmAbort, titleVisibility: .visible) {
                    Button("Abort Operation", role: .destructive, action: store.abortOperation)
                } message: { Text("Git will restore the pre-operation state. Edits made while resolving conflicts may be lost.") }
        }
    }
}
