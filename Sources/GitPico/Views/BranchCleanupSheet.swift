import GitCore
import SwiftUI

struct BranchCleanupSheet: View {
    let store: RepositoryStore
    let base: String
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [BranchCleanupCandidate] = []
    @State private var selected: Set<String> = []
    @State private var staleDays = 90
    @State private var loading = true
    @State private var error: String?
    private var targets: [Reference] { candidates.filter { selected.contains($0.id) && $0.canArchive }.map(\.branch) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle("Review Branch Cleanup")
            Text("Archive branches to hide them from the sidebar. Commits and branch references are kept; unarchive them at any time.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("Compared with \(base.replacingOccurrences(of: "refs/heads/", with: ""))").font(.callout)
                Spacer()
                Picker("Inactive for", selection: $staleDays) {
                    Text("30 days").tag(30); Text("90 days").tag(90); Text("180 days").tag(180)
                }.fixedSize()
            }
            if loading { ProgressView("Checking local branches…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                List(candidates) { candidate in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) } })) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(candidate.branch.name).fontWeight(.medium)
                                Text(candidate.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                if let protection = candidate.protection { Label(protection, systemImage: "lock").font(.caption).foregroundStyle(Pico.warning) }
                            }
                        }.toggleStyle(.checkbox).disabled(!candidate.canArchive)
                        Spacer()
                        Text(candidate.lastCommitDate.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }.listStyle(.bordered)
                    .overlay { if candidates.isEmpty { Text("No cleanup suggestions for this base.").foregroundStyle(.secondary) } }
            }
            Text("Tracking status reflects the last fetch. Patch equivalence is a review hint, not proof of a hosted PR merge. Combined patches are compared with the last 200 first-parent commits in the base.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(Pico.deletion).textSelection(.enabled) }
            HStack {
                Button("Select Eligible") { selected = Set(candidates.filter(\.canArchive).map(\.id)) }.disabled(loading)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Archive \(targets.count) Branches") {
                    let branches = targets
                    store.perform("Archiving branches…") { try await $0.archiveCleanupBranches(branches) }
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(loading || targets.isEmpty || store.isBusy)
            }
        }.padding(24).frame(width: 720, height: 580)
            .task(id: staleDays) {
                loading = true; error = nil; selected = []; candidates = []
                guard let repository = store.repository else { loading = false; return }
                do {
                    let value = try await repository.branchCleanupCandidates(base: base, staleDays: staleDays)
                    guard !Task.isCancelled else { return }
                    candidates = value; loading = false
                } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
            }
    }
}
