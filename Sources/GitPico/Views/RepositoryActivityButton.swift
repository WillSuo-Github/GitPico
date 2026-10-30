import GitCore
import SwiftUI

/// A permanent, fixed-width entry point keeps transient feedback away from repository information.
struct RepositoryActivityButton: View {
    let store: RepositoryStore
    @State private var showingDetails = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.repositoryStatusMotionEnabled) private var motionEnabled
    @Environment(\.colorScheme) private var colorScheme
    private var reduceMotion: Bool { systemReduceMotion || !motionEnabled }

    private var stateAnimation: Animation? { RepositoryStatusBarBackground.transition(isRunning: store.isBusy, reduceMotion: reduceMotion) }

    private var feedback: RepositoryOperationFeedback? { store.operationFeedback }
    private var needsReview: Bool { feedback?.isVisible == true && (feedback?.phase == .failed || feedback?.warning != nil) }
    private var foreground: Color { .primary }
    private var emphasis: Color { needsReview ? Pico.warning : .accentColor }
    private var highlight: Color {
        if store.isBusy { return emphasis.opacity(colorScheme == .dark ? 0.2 : 0.12) }
        if needsReview { return emphasis.opacity(0.1) }
        return Color.primary.opacity(hovering || showingDetails ? 0.06 : 0)
    }
    private var title: String {
        if store.isBusy {
            guard let feedback, feedback.phase == .running else { return store.activity }
            if feedback.isRefreshing { return String(localized: "Refreshing…") }
            switch feedback.command {
            case .fetch: return String(localized: "Fetching…")
            case .pull: return String(localized: "Pulling…")
            case .push: return String(localized: "Pushing…")
            case .synchronize: return String(localized: "Synchronizing…")
            case .local: return feedback.title
            }
        }
        return needsReview ? String(localized: "Review") : String(localized: "Activity")
    }
    private var symbol: String {
        guard let feedback, feedback.isVisible else { return "clock.arrow.circlepath" }
        return feedback.activitySymbol
    }
    private var color: Color {
        guard !store.isBusy, let feedback, feedback.isVisible else { return foreground }
        return feedback.activityTint
    }

    var body: some View {
        Button { showingDetails.toggle() } label: {
            HStack(spacing: 6) {
                if store.isBusy { ProgressView().controlSize(.mini).tint(.accentColor) }
                else { Image(systemName: symbol).animation(stateAnimation) { $0.foregroundStyle(color) }.frame(width: 12) }
                Text(title).fontWeight(store.isBusy || needsReview ? .medium : .regular).lineLimit(1).truncationMode(.tail).animation(stateAnimation) { $0.foregroundStyle(foreground) }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up").font(.system(size: 8, weight: .medium)).animation(stateAnimation) { $0.foregroundStyle(foreground.opacity(0.65)) }
            }
            .padding(.horizontal, 7).frame(width: 148, height: 22)
            .background {
                RoundedRectangle(cornerRadius: 5).fill(highlight)
                    .animation(stateAnimation, value: store.isBusy)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(emphasis.opacity(store.isBusy || needsReview ? 0.18 : 0), lineWidth: 0.5)
                    .animation(stateAnimation, value: store.isBusy)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(store.isBusy ? (feedback?.phase == .running ? feedback?.title ?? title : title) : feedback?.title ?? String(localized: "Show operation details"))
        .accessibilityLabel("Activity")
        .accessibilityValue(store.isBusy ? title : feedback?.title ?? String(localized: "No recent operation"))
        .onChange(of: store.snapshot?.root) { showingDetails = false }
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            RepositoryActivityDetailsView(store: store, close: { showingDetails = false })
        }
    }
}

struct RepositoryActivityDetailsView: View {
    let store: RepositoryStore
    var close: () -> Void = {}

    private var feedback: RepositoryOperationFeedback? {
        if store.isBusy, store.operationFeedback?.phase != .running { return nil }
        return store.operationFeedback
    }
    private var latestNetworkRecord: NetworkActivityRecord? {
        guard let path = store.snapshot?.root.path else { return nil }
        return store.networkActivity?.records.first { $0.repositoryPath == path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close")
            }
            if let feedback {
                Label(feedback.title, systemImage: feedback.activitySymbol)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(feedback.activityTint)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let end = feedback.phase == .running ? context.date : store.feedbackFinishedAt ?? context.date
                    Text(feedback.started.formatted(date: .omitted, time: .standard) + " · " + Duration.seconds(max(0, end.timeIntervalSince(feedback.started))).formatted(.units(allowed: [.seconds], width: .wide)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let detail = feedback.warning ?? feedback.failure {
                    ScrollView { Text(detail).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 180)
                }
            } else if store.isBusy {
                Label(store.activity, systemImage: "arrow.triangle.2.circlepath").font(.callout)
            } else if let record = latestNetworkRecord {
                Label(String(localized: networkCommandTitle(record.command)) + " · " + record.phase.title, systemImage: record.phase == .running ? "arrow.triangle.2.circlepath" : "network")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(record.started.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No recent operation").font(.callout)
                Text("Run an operation to see its progress and latest result here.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Network Activity") { close(); store.inspectOperationNetworkActivity() }
                Spacer(minLength: 0)
                if let feedback, feedback.phase != .running {
                    Button("Clear") { store.dismissOperationFeedback(feedback.id); close() }
                }
            }.controlSize(.small)
        }.padding(16).frame(width: 360, alignment: .leading)
    }
}

private extension RepositoryOperationFeedback {
    var activitySymbol: String {
        if warning != nil { return "exclamationmark.triangle.fill" }
        switch phase {
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "stop.circle"
        }
    }
    var activityTint: Color {
        if warning != nil { return Pico.warning }
        switch phase {
        case .running: return .accentColor
        case .succeeded: return Pico.addition
        case .failed: return Pico.deletion
        case .cancelled: return .secondary
        }
    }
}
