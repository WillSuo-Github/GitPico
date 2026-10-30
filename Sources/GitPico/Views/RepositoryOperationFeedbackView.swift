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
