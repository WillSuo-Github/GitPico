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
        if unavailable { return String(localized: "Current branch · \(upstream)\nUpstream unavailable locally. Fetch or select another tracking branch; divergence is unknown.") }
        guard !upstream.isEmpty else { return String(localized: "Current branch. No upstream configured; set a tracking branch to show outgoing and incoming commit counts.") }
        return String(localized: "Current branch · \(upstream)\n\(ahead) outgoing commits · \(behind) incoming commits\nCompared with local upstream refs. Fetch to refresh remote state.")
    }
}

struct CurrentBranchBadge: View {
    let status: BranchSyncStatus
    var isSelected = false
    @Environment(\.self) private var environment
    var body: some View {
        let accent = Color.accentColor.resolve(in: environment)
        let luminance = 0.2126 * accent.linearRed + 0.7152 * accent.linearGreen + 0.0722 * accent.linearBlue
        // Choose the higher-contrast black or white ink for the resolved accent.
        let ink: Color = luminance > 0.179 ? .black : .white
        let highlighted = isSelected || environment.backgroundProminence == .increased
        Text(status.text)
            .font(.system(size: 9)).bold().monospacedDigit().fixedSize()
            .foregroundStyle(ink)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.accentColor, in: Capsule())
            .overlay { Capsule().strokeBorder(highlighted ? ink : .clear, lineWidth: 1.5) }
            .help(status.help)
            .accessibilityLabel(status.help)
    }
}
