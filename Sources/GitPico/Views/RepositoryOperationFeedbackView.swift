import GitCore
import SwiftUI

struct RepositorySyncButton: View {
    enum Action {
        case fetch, pull, push
        var kind: RepositoryOperationKind { switch self { case .fetch: .fetch; case .pull: .pull; case .push: .push } }
        var title: LocalizedStringResource { switch self { case .fetch: "Fetch"; case .pull: "Pull"; case .push: "Push" } }
        var runningTitle: LocalizedStringResource { switch self { case .fetch: "Fetching…"; case .pull: "Pulling…"; case .push: "Pushing…" } }
        var symbol: String { switch self { case .fetch: "arrow.down.circle"; case .pull: "arrow.down"; case .push: "arrow.up" } }
    }
    let store: RepositoryStore
    let action: Action

    private var running: Bool {
        if action == .fetch && store.isFetching { return true }
        return store.operationFeedback?.phase == .running && (store.operationFeedback?.command == action.kind || (action == .pull && store.operationFeedback?.command == .synchronize))
    }
    private var runningTitle: LocalizedStringResource {
        store.operationFeedback?.command == .synchronize ? "Synchronizing…" : action.runningTitle
    }
    private var help: String {
        if running { return String(localized: "Network progress, recent operations and authentication") }
        switch action {
        case .fetch: return String(localized: "Fetch all remotes")
        case .pull: return String(localized: "Review Pull strategy (\(AppPreferences.shared.pullPolicy.title))")
        case .push: return String(localized: "Push current branch")
        }
    }

    var body: some View {
        Button {
            if running { store.showingNetworkActivity = true }
            else {
                switch action {
                case .fetch: store.sync(.fetch)
                case .pull: store.reviewPull()
                case .push: store.sync(.push)
                }
            }
        } label: {
            if running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(runningTitle).foregroundStyle(Color.accentColor)
                }
            } else {
                Label(action.title, systemImage: action.symbol)
            }
        }
        .disabled(!running && (!store.canUseRepository || store.snapshot?.remotes.isEmpty != false || (action != .fetch && !store.canIntegrate)))
        .help(help)
        .accessibilityLabel(running ? runningTitle : action.title)
    }
}

struct RepositoryOperationFeedbackView: View {
    let store: RepositoryStore

    var body: some View {
        if let feedback = store.operationFeedback, feedback.isVisible {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let running = feedback.phase == .running
                let message = running ? String(localized: "Running for \(max(0, Int(context.date.timeIntervalSince(feedback.started)))) seconds") : (feedback.warning ?? feedback.failure)?.components(separatedBy: .newlines).first
                NoticeBanner(icon: symbol(feedback), title: "\(feedback.title)", message: message, tint: tint(feedback)) {
                    if running { ProgressView().controlSize(.small) }
                    if store.feedbackNetworkRecord != nil || feedback.command != .local {
                        Button("Details") { store.showingNetworkActivity = true }.buttonStyle(.borderless)
                    } else if let detail = feedback.warning ?? feedback.failure {
                        Button("Details") { store.error = detail }.buttonStyle(.borderless)
                    }
                    if !running {
                        Button { store.dismissOperationFeedback(feedback.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func symbol(_ feedback: RepositoryOperationFeedback) -> String {
        if feedback.warning != nil { return "exclamationmark.triangle.fill" }
        switch feedback.phase { case .running: return "arrow.triangle.2.circlepath"; case .succeeded: return "checkmark.circle.fill"; case .failed: return "exclamationmark.triangle.fill"; case .cancelled: return "stop.circle.fill" }
    }
    private func tint(_ feedback: RepositoryOperationFeedback) -> Color {
        if feedback.warning != nil { return Pico.warning }
        switch feedback.phase { case .running: return .accentColor; case .succeeded: return Pico.addition; case .failed: return Pico.deletion; case .cancelled: return Pico.warning }
    }
}
