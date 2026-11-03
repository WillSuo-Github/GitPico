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
    private var latestRecord: NetworkActivityRecord? { feedback == nil ? store.latestStatusNetworkRecord : nil }
    private var resultTitle: String? { feedback?.title ?? latestRecord?.activityTitle }
    private var needsReview: Bool { !store.isBusy && feedback?.isVisible == true && (feedback?.phase == .failed || feedback?.warning != nil) }
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
        return resultTitle ?? String(localized: "Activity")
    }
    private var symbol: String {
        feedback?.activitySymbol ?? latestRecord?.phase.activitySymbol ?? "clock.arrow.circlepath"
    }
    private var color: Color {
        guard !store.isBusy else { return foreground }
        if let feedback { return feedback.isVisible ? feedback.activityTint : .secondary }
        return latestRecord == nil ? foreground : .secondary
    }

    var body: some View {
        let progress = store.activeStatusNetworkRecord?.transferProgress
        let description = progress.map { $0.stage + " · " + $0.formattedPercent }
        let help = description ?? (store.isBusy ? title : resultTitle ?? String(localized: "Show operation details"))
        let accessibility = description.map { title + " · " + $0 } ??
            (store.isBusy ? title : resultTitle ?? String(localized: "No recent operation"))
        Button { showingDetails.toggle() } label: { label(progress) }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
            .accessibilityLabel("Activity")
            .accessibilityValue(Text(accessibility))
            .onChange(of: store.snapshot?.root) { showingDetails = false }
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                RepositoryActivityDetailsView(store: store, close: { showingDetails = false })
            }
    }

    private func label(_ progress: GitTransferProgress?) -> some View {
        HStack(spacing: 6) {
            if store.isBusy && progress == nil {
                ProgressView().controlSize(.mini).tint(.accentColor).accessibilityHidden(true)
            } else if !store.isBusy {
                Image(systemName: symbol).animation(stateAnimation) { $0.foregroundStyle(color) }.frame(width: 12)
            }
            activityText
                .fontWeight(store.isBusy || needsReview ? .medium : .regular)
                .lineLimit(1).foregroundStyle(foreground)
            Spacer(minLength: 0)
            if let progress {
                Text(progress.formattedPercent)
                    .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
            }
            Image(systemName: "chevron.up").font(.system(size: 8, weight: .medium)).foregroundStyle(foreground.opacity(0.65))
        }
        .padding(.horizontal, 7).padding(.bottom, progress == nil ? 0 : 3).frame(width: 164, height: 22)
        .background {
            RoundedRectangle(cornerRadius: 5).fill(highlight).animation(stateAnimation, value: store.isBusy)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5).strokeBorder(emphasis.opacity(store.isBusy || needsReview ? 0.18 : 0), lineWidth: 0.5)
                .animation(stateAnimation, value: store.isBusy)
        }
        .overlay(alignment: .bottom) {
            if let progress { progressTrack(progress.fraction) }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var activityText: some View {
        if !store.isBusy, let outcome = feedback?.outcomeTitle ?? latestRecord?.phase.title {
            ViewThatFits(in: .horizontal) {
                Text(title).fixedSize(horizontal: true, vertical: false)
                Text(outcome)
            }
        } else {
            Text(title)
        }
    }

    private func progressTrack(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            Capsule().fill(emphasis.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule().fill(emphasis)
                        .frame(width: geometry.size.width * CGFloat(fraction))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: fraction)
                }
        }
        .frame(height: 2).padding(.horizontal, 7).padding(.bottom, 2)
        .allowsHitTesting(false).accessibilityHidden(true)
    }

}

struct RepositoryActivityDetailsView: View {
    let store: RepositoryStore
    var close: () -> Void = {}

    private var feedback: RepositoryOperationFeedback? {
        if store.isBusy, store.operationFeedback?.phase != .running { return nil }
        return store.operationFeedback
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
            if store.isBusy {
                if let progress = store.activeStatusNetworkRecord?.transferProgress {
                    ProgressView(value: progress.fraction) {
                        Text(progress.stage)
                    } currentValueLabel: {
                        Text("Git's current phase: \(progress.percent)%")
                    }
                    .font(.caption)
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel(Text(store.activity))
                }
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
