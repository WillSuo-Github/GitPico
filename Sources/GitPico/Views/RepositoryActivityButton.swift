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
    var isRunning: Bool { store.isPerformingStatusActivity }

    private var stateAnimation: Animation? { RepositoryStatusBarBackground.transition(isRunning: isRunning, reduceMotion: reduceMotion) }

    private var feedback: RepositoryOperationFeedback? { store.operationFeedback }
    private var latestRecord: NetworkActivityRecord? { feedback == nil ? store.latestStatusNetworkRecord : nil }
    private var resultTitle: String? { feedback?.title ?? latestRecord?.activityTitle }
    private var needsReview: Bool { !isRunning && feedback?.isVisible == true && (feedback?.phase == .failed || feedback?.warning != nil) }
    private var foreground: Color { .primary }
    private var emphasis: Color { needsReview ? Pico.warning : .accentColor }
    private var highlight: Color {
        if isRunning { return emphasis.opacity(colorScheme == .dark ? 0.2 : 0.12) }
        if needsReview { return emphasis.opacity(0.1) }
        return Color.primary.opacity(hovering || showingDetails ? 0.06 : 0)
    }
    var title: String {
        if isRunning {
            if let feedback, feedback.phase == .running {
                if feedback.isRefreshing { return String(localized: "Refreshing…") }
                switch feedback.command {
                case .fetch: return String(localized: "Fetching…")
                case .pull: return String(localized: "Pulling…")
                case .push: return String(localized: "Pushing…")
                case .synchronize: return String(localized: "Synchronizing…")
                case .local: return feedback.title
                }
            }
            if store.showsRepositoryStatus && store.isBackgroundFetching { return String(localized: "Fetching remote updates…") }
            return store.activity
        }
        return resultTitle ?? String(localized: "Activity")
    }
    var symbol: String {
        feedback?.activitySymbol ?? latestRecord?.phase.activitySymbol ?? "clock.arrow.circlepath"
    }
    private var color: Color {
        guard !isRunning else { return foreground }
        if let feedback { return feedback.isVisible ? feedback.activityTint : .secondary }
        return latestRecord == nil ? foreground : .secondary
    }

    var body: some View {
        let progress = store.activeStatusNetworkRecord?.transferProgress
        let description = progress.map { $0.stage + " · " + $0.formattedPercent }
        let help = description ?? (isRunning ? title : resultTitle ?? String(localized: "Show operation details"))
        let accessibility = description.map { title + " · " + $0 } ??
            (isRunning ? title : resultTitle ?? String(localized: "No recent operation"))
        Button { showingDetails.toggle() } label: { label(progress) }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
            .accessibilityLabel("Activity")
            .accessibilityValue(Text(accessibility))
            .onChange(of: store.snapshot?.root) { showingDetails = false }
            .onChange(of: store.isChoosingRepository) { showingDetails = false }
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                RepositoryActivityDetailsView(store: store, close: { showingDetails = false })
            }
    }

    private func label(_ progress: GitTransferProgress?) -> some View {
        HStack(spacing: 6) {
            if isRunning && progress == nil {
                ProgressView().controlSize(.mini).tint(.accentColor).accessibilityHidden(true)
            } else if !isRunning {
                Image(systemName: symbol).animation(stateAnimation) { $0.foregroundStyle(color) }.frame(width: 12)
            }
            activityText
                .fontWeight(isRunning || needsReview ? .medium : .regular)
                .lineLimit(1).foregroundStyle(foreground)
            Spacer(minLength: 0)
            if let progress {
                Text(progress.formattedPercent)
                    .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
            }
            Image(systemName: "chevron.up").font(.system(size: 8, weight: .medium)).foregroundStyle(foreground.opacity(0.65))
        }
        .padding(.horizontal, 7).padding(.bottom, isRunning ? 3 : 0).frame(width: 164, height: 22)
        .background {
            RoundedRectangle(cornerRadius: 5).fill(highlight).animation(stateAnimation, value: isRunning)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5).strokeBorder(emphasis.opacity(isRunning || needsReview ? 0.18 : 0), lineWidth: 0.5)
                .animation(stateAnimation, value: isRunning)
        }
        .overlay(alignment: .bottom) {
            if isRunning {
                RepositoryProgressSweepBar(fraction: progress?.fraction, tint: emphasis, height: 2, reduceMotion: reduceMotion)
                    .padding(.horizontal, 7)
                    .padding(.bottom, 2)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var activityText: some View {
        if !isRunning, let outcome = feedback?.outcomeTitle ?? latestRecord?.phase.title {
            ViewThatFits(in: .horizontal) {
                Text(title).fixedSize(horizontal: true, vertical: false)
                Text(outcome)
            }
        } else {
            Text(title)
        }
    }
}

struct RepositoryActivityDetailsView: View {
    let store: RepositoryStore
    var close: () -> Void = {}
    @State private var pendingCancelID: UUID?

    private var isRunning: Bool { store.isPerformingStatusActivity }
    private var feedback: RepositoryOperationFeedback? {
        if isRunning, store.operationFeedback?.phase != .running { return nil }
        return store.operationFeedback
    }
    private var runningLabel: String {
        if !store.activity.isEmpty { return store.activity }
        if store.showsRepositoryStatus && store.isBackgroundFetching { return String(localized: "Fetching remote updates…") }
        return String(localized: "Fetching…")
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
            } else if isRunning {
                Label(runningLabel, systemImage: "arrow.triangle.2.circlepath").font(.callout)
            } else if let record = store.latestStatusNetworkRecord {
                Label(record.activityTitle, systemImage: record.phase.activitySymbol)
                    .font(.callout).foregroundStyle(record.phase.activityTint).fixedSize(horizontal: false, vertical: true)
                Text((record.finished ?? record.started).formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                if record.phase == .failed || record.phase == .cancelled {
                    Text(networkFailureAdvice(record.output, timedOut: record.timedOut == true)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No recent operation").font(.callout)
                Text("Run an operation to see its progress and latest result here.").font(.caption).foregroundStyle(.secondary)
            }
            if isRunning {
                if let progress = store.activeStatusNetworkRecord?.transferProgress {
                    ProgressView(value: progress.fraction) {
                        Text(progress.stage)
                    } currentValueLabel: {
                        Text("Git's current phase: \(progress.percent)%")
                    }
                    .font(.caption)
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel(Text(runningLabel))
                }
            }
            HStack {
                Button("Network Activity") { close(); store.inspectOperationNetworkActivity() }
                Spacer(minLength: 0)
                if let record = store.activeStatusNetworkRecord {
                    Button("Cancel") {
                        if record.command == "clone" && store.cloneSession?.networkRecordID == record.id {
                            store.cancelActiveClone()
                        } else if record.command == "fetch" {
                            store.networkActivity?.cancel(record.id)
                        } else {
                            pendingCancelID = record.id
                        }
                    }
                }
                if let feedback, feedback.phase != .running {
                    Button("Clear") { store.dismissOperationFeedback(feedback.id); close() }
                }
            }.controlSize(.small)
        }.padding(16).frame(width: 360, alignment: .leading)
        .confirmationDialog("Cancel the network operation?", isPresented: Binding(get: { pendingCancelID != nil }, set: { if !$0 { pendingCancelID = nil } })) {
            Button("Cancel Operation", role: .destructive) {
                if let pendingCancelID { store.networkActivity?.cancel(pendingCancelID) }
                pendingCancelID = nil
            }
        } message: {
            Text("Git or the server may already have changed. Review the refreshed state before retrying. Push and Pull are never retried automatically.")
        }
    }
}

private extension RepositoryOperationFeedback {
    var activitySymbol: String {
        if warning != nil { return "exclamationmark.triangle.fill" }
        return phase.activitySymbol
    }
    var activityTint: Color { warning == nil ? phase.activityTint : Pico.warning }
}

private extension NetworkActivityRecord {
    var activityTitle: String { String(localized: networkCommandTitle(command)) + " · " + phase.title }
}

private extension GitNetworkEvent.Phase {
    var activitySymbol: String {
        switch self {
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "stop.circle"
        }
    }
    var activityTint: Color {
        switch self {
        case .running: return .accentColor
        case .succeeded: return Pico.addition
        case .failed: return Pico.deletion
        case .cancelled: return .secondary
        }
    }
}

private extension GitTransferProgress {
    var formattedPercent: String { fraction.formatted(.percent.precision(.fractionLength(0))) }
}
