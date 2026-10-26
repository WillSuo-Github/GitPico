import GitCore
import SwiftUI

struct PullReviewRequest: Identifiable {
    let id = UUID()
    let head: HeadPosition
    let upstream: String
    var pushAfter = false
}

struct PullReviewSheet: View {
    let store: RepositoryStore
    let request: PullReviewRequest
    @State private var policy = AppPreferences.shared.pullPolicy
    @State private var remember = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(request.pushAfter ? "Synchronize Changes" : "Pull Changes", icon: "arrow.down")
            Text("Fetch and integrate into “" + (store.snapshot?.branch ?? "current branch") + "”.").foregroundStyle(.secondary)
            if request.upstream.isEmpty {
                Label("Choose a tracking branch before pulling.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                LabeledContent("Upstream", value: request.upstream)
                if store.snapshot?.unresolvedUpstream != nil {
                    Text("The upstream is not available locally. Pull will fetch it; if it was deleted, update the tracking branch.").font(.callout).foregroundStyle(.orange)
                }
            }
            if store.snapshot?.unresolvedUpstream == nil && !request.upstream.isEmpty {
                Text("Local refs show \(store.snapshot?.ahead ?? 0) outgoing and \(store.snapshot?.behind ?? 0) incoming commits. Fetch may reveal newer remote changes.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Outgoing and incoming counts are unavailable until the upstream resolves.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Strategy", selection: $policy) {
                ForEach(PullPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text(policy.explanation).font(.callout)
            if policy == .rebase { Label("Do not rebase commits others already depend on.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            Toggle("Use this as the default Pull strategy", isOn: $remember)
            Text("Conflicts pause the operation in Working Copy, where you can resolve, continue or abort.").font(.caption).foregroundStyle(.secondary)
            if request.pushAfter { Text("After a successful Pull, push the current branch to its configured upstream.").font(.callout) }
            HStack {
                Button("Tracking Branch…") { store.trackingAfterPull = true; dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.pushAfter ? "Synchronize" : "Pull") {
                    if remember { AppPreferences.shared.pullPolicy = policy }
                    store.runPull(request, policy: policy); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(request.upstream.isEmpty || !store.canIntegrate)
            }
        }.padding(24).frame(width: 540)
    }
}

extension RepositoryStore {
    func runPull(_ request: PullReviewRequest, policy: PullPolicy) {
        guard canIntegrate else { return }
        protectedPerform("Pull (" + policy.title + ")…", refresh: .workingTree) {
            try await $0.pull(policy: policy, expectedHead: request.head, expectedUpstream: request.upstream)
            if request.pushAfter { try await $0.sync(.push) }
        }
    }
    func finishPullReview() {
        if trackingAfterPull { trackingAfterPull = false; reviewTrackingBranch() }
        else { presentPendingAutomaticStash() }
    }
    func reviewTrackingBranch() {
        guard let current = snapshot?.references.first(where: { $0.isCurrent && $0.isLocal }) else { return }
        managementRequest = ManagementRequest(action: .upstream(current))
    }
}

struct UpstreamRecoveryBanner: View {
    let store: RepositoryStore
    var body: some View {
        if let missing = store.snapshot?.unresolvedUpstream {
            NoticeBanner(icon: "exclamationmark.triangle.fill", title: "Upstream unavailable", message: missing + " is missing locally. Fetch it or select another tracking branch.") {
                Button("Fetch") { store.sync(.fetch) }.disabled(!store.canUseRepository)
                Button("Tracking Branch…") { store.reviewTrackingBranch() }.disabled(!store.canUseRepository)
            }
        }
    }
}
