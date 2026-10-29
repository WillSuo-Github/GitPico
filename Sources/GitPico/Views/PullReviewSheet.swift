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
    private var branch: String { store.snapshot?.branch ?? String(localized: "current branch") }
    private var savedPolicy: PullPolicy { AppPreferences.shared.pullPolicy }
    private var upstreamResolved: Bool { store.snapshot?.unresolvedUpstream == nil && !request.upstream.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                header
                route
                strategy
                notes
            }.padding(22)
            Divider()
            footer.padding(.horizontal, 22).padding(.vertical, 14)
        }.frame(width: 540)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: request.pushAfter ? "arrow.triangle.2.circlepath" : "arrow.down").font(.system(size: 16, weight: .semibold)).foregroundStyle(.tint)
                .frame(width: 36, height: 36).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(request.pushAfter ? "Synchronize Changes" : "Pull Changes").font(.system(size: 17, weight: .bold, design: .rounded))
                Text(request.pushAfter ? String(localized: "Fetch, integrate and push “\(branch)”.") : String(localized: "Fetch and integrate into “\(branch)”.")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }

    /// Upstream → local branch, with the locally known incoming/outgoing counts.
    @ViewBuilder private var route: some View {
        if request.upstream.isEmpty {
            callout("exclamationmark.triangle.fill", String(localized: "No tracking branch"), String(localized: "Choose a tracking branch before pulling."), tint: Pico.warning)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    endpoint(icon: "cloud", caption: String(localized: "Upstream"), name: request.upstream)
                    Image(systemName: "arrow.forward").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                    endpoint(icon: "arrow.triangle.branch", caption: String(localized: "Into"), name: branch)
                    Spacer(minLength: 4)
                    if upstreamResolved {
                        HStack(spacing: 5) {
                            Chip(text: "\(store.snapshot?.behind ?? 0)", icon: "arrow.down", tint: (store.snapshot?.behind ?? 0) > 0 ? .accentColor : .secondary).help("Incoming commits known locally")
                            Chip(text: "\(store.snapshot?.ahead ?? 0)", icon: "arrow.up", tint: (store.snapshot?.ahead ?? 0) > 0 ? .accentColor : .secondary).help("Outgoing commits")
                        }
                    }
                }
                Text(upstreamResolved ? "Counts reflect local refs. Fetch may reveal newer remote commits." : "The upstream is not available locally. Pull will fetch it; if it was deleted, update the tracking branch.")
                    .font(.system(size: 11)).foregroundStyle(upstreamResolved ? AnyShapeStyle(.secondary) : AnyShapeStyle(Pico.warning)).fixedSize(horizontal: false, vertical: true)
            }.card(padding: 12)
        }
    }

    private func endpoint(icon: String, caption: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Label(name, systemImage: icon).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
        }
    }

    private var strategy: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("Strategy")
            VStack(spacing: 6) {
                ForEach(PullPolicy.allCases, id: \.self) { option in strategyRow(option) }
            }
            if policy != savedPolicy {
                Toggle("Make “\(policy.title)” the default Pull strategy", isOn: $remember).font(.system(size: 12)).padding(.top, 2)
            }
        }
    }

    private func strategyRow(_ option: PullPolicy) -> some View {
        let selected = option == policy
        return Button { policy = option } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.system(size: 14)).foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(option.title).font(.system(size: 13, weight: .semibold))
                        if option == savedPolicy { Chip(text: String(localized: "Default")) }
                    }
                    Text(option.explanation).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if option == .rebase && selected {
                        Label("Do not rebase commits others already depend on.", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Pico.warning).padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: Self.symbol(option)).font(.system(size: 14, weight: .medium)).foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)).frame(width: 20).padding(.top, 1)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: Pico.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Pico.corner, style: .continuous).strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.6), lineWidth: selected ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: Pico.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .animation(.easeOut(duration: 0.15), value: policy)
    }

    private static func symbol(_ option: PullPolicy) -> String {
        switch option {
        case .merge: "arrow.triangle.merge"
        case .rebase: "arrow.triangle.swap"
        }
    }

    @ViewBuilder private var notes: some View {
        VStack(alignment: .leading, spacing: 5) {
            if request.pushAfter {
                Label("After a successful Pull, push the current branch to its configured upstream.", systemImage: "arrow.up.circle").foregroundStyle(.secondary)
            }
            Label("Conflicts pause the operation in Working Copy, where you can resolve, continue or abort.", systemImage: "info.circle").foregroundStyle(.secondary)
        }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
    }

    private func callout(_ icon: String, _ title: String, _ message: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12).background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Pico.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Pico.corner, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
    }

    private var footer: some View {
        HStack {
            Button("Tracking Branch…") { store.trackingAfterPull = true; dismiss() }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(request.pushAfter ? "Synchronize" : "Pull") {
                if remember && policy != savedPolicy { AppPreferences.shared.pullPolicy = policy }
                store.runPull(request, policy: policy); dismiss()
            }.keyboardShortcut(.defaultAction).disabled(request.upstream.isEmpty || !store.canIntegrate)
        }.controlSize(.large)
    }
}

extension RepositoryStore {
    func runPull(_ request: PullReviewRequest, policy: PullPolicy) {
        guard canIntegrate else { return }
        protectedPerform(request.pushAfter ? "Synchronizing…" : "Pull (\(policy.title))…", refresh: .workingTree, feedback: request.pushAfter ? .synchronize : .pull) {
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
            NoticeBanner(icon: "exclamationmark.triangle.fill", title: "Upstream unavailable", message: String(localized: "\(missing) is missing locally. Fetch it or select another tracking branch.")) {
                Button("Fetch") { store.sync(.fetch) }.disabled(!store.canUseRepository)
                Button("Tracking Branch…") { store.reviewTrackingBranch() }.disabled(!store.canUseRepository)
            }
        }
    }
}
