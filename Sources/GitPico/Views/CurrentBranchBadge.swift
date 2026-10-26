import GitCore
import SwiftUI

struct BranchSyncStatus: Equatable {
    let upstream: String
    let ahead: Int
    let behind: Int
    var unavailable = false

    static func current(_ reference: Reference, snapshot: RepositorySnapshot?) -> Self? {
        guard reference.isCurrent, reference.isLocal, let snapshot,
              snapshot.head.branch == reference.fullName,
              let current = snapshot.references.first(where: { $0.isCurrent && $0.fullName == reference.fullName }) else { return nil }
        return Self(upstream: current.upstream, ahead: snapshot.ahead, behind: snapshot.behind, unavailable: snapshot.unresolvedUpstream != nil)
    }

    var text: String {
        if unavailable { return "HEAD | ?" }
        var counts: [String] = []
        if !upstream.isEmpty {
            if ahead > 0 { counts.append("↑\(ahead)") }
            if behind > 0 { counts.append("↓\(behind)") }
        }
        return counts.isEmpty ? "HEAD" : "HEAD | " + counts.joined(separator: " ")
    }

    var help: String {
        if unavailable { return "Current branch · \(upstream)\nUpstream unavailable locally. Fetch or select another tracking branch; divergence is unknown." }
        guard !upstream.isEmpty else { return "Current branch. No upstream configured; set a tracking branch to show outgoing and incoming commit counts." }
        return "Current branch · \(upstream)\n\(ahead) outgoing commits · \(behind) incoming commits\nCompared with local upstream refs. Fetch to refresh remote state."
    }
}

struct CurrentBranchBadge: View {
    let status: BranchSyncStatus
    var body: some View {
        Text(status.text)
            .font(.system(size: 9, weight: .bold)).monospacedDigit().fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help(status.help)
            .accessibilityLabel(status.help)
    }
}
