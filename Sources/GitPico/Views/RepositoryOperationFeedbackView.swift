import AppKit
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
        case .fetch: return String(localized: "Fetch Options…")
        case .pull: return String(localized: "Review Pull strategy (\(AppPreferences.shared.pullPolicy.title))")
        case .push: return String(localized: "Push current branch")
        }
    }
    private var disabled: Bool {
        if running { return false }
        switch action {
        case .fetch: return !store.canFetch
        case .pull, .push: return !store.canRemoteIntegrate
        }
    }

    var body: some View {
        Button {
            if running { store.showingNetworkActivity = true }
            else {
                switch action {
                case .fetch: store.reviewFetch()
                case .pull: store.reviewPull()
                case .push: store.sync(.push)
                }
            }
        } label: {
            if running {
                ProgressView()
                    .controlSize(.small)
                    .tint(.accentColor)
                    .frame(width: 18, height: 18)
            } else {
                Label(action.title, systemImage: action.symbol)
            }
        }
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(running ? runningTitle : action.title)
    }
}

struct RepositoryToolbarActivityView: View {
    let store: RepositoryStore
    @State private var showingDetails = false
    @State private var hovering = false
    @State private var hoveringAction = false
    @State private var pendingCancelID: UUID?
    @State private var windowWidth: CGFloat = 1440
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.repositoryStatusMotionEnabled) private var motionEnabled

    private var reduceMotion: Bool { systemReduceMotion || !motionEnabled }
    private var isCompactWidth: Bool { windowWidth < 1220 }
    private var capsuleMaxWidth: CGFloat { isCompactWidth ? 168 : 320 }
    private var percentColor: Color {
        colorScheme == .dark ? .primary : statusTint
    }
    private var feedback: RepositoryOperationFeedback? {
        guard let current = store.operationFeedback, current.isVisible else { return nil }
        return current
    }
    private var isRunning: Bool { feedback?.phase == .running }
    private var activeRecord: NetworkActivityRecord? {
        guard isRunning else { return nil }
        return store.activeStatusNetworkRecord
    }
    private var progress: GitTransferProgress? { activeRecord?.transferProgress }
    private var statusTint: Color {
        guard let feedback else { return .accentColor }
        if feedback.phase == .running { return .accentColor }
        if feedback.warning != nil { return Pico.warning }
        switch feedback.phase {
        case .running: return .accentColor
        case .succeeded: return Pico.addition
        case .failed: return Pico.deletion
        case .cancelled: return .secondary
        }
    }
    private var statusSymbol: String {
        guard let feedback else { return "arrow.triangle.2.circlepath" }
        if feedback.warning != nil { return "exclamationmark.triangle.fill" }
        switch feedback.phase {
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }
    private var splitActivity: (primary: String, detail: String?) {
        guard let feedback else { return ("", nil) }
        if feedback.phase == .running {
            if feedback.isRefreshing {
                let name = feedback.command.title ?? feedback.activity.trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
                return (name, String(localized: "Refreshing…"))
            }
            if progress != nil || isCompactWidth {
                switch feedback.command {
                case .fetch: return (String(localized: "Fetching…"), nil)
                case .pull: return (String(localized: "Pulling…"), nil)
                case .push: return (String(localized: "Pushing…"), nil)
                case .synchronize: return (String(localized: "Synchronizing…"), nil)
                case .local: break
                }
            }
            let parts = feedback.activity.components(separatedBy: " · ")
            if parts.count >= 2 {
                return (parts[0], parts.dropFirst().joined(separator: " · "))
            }
            return (feedback.activity, nil)
        }
        let name = feedback.command.title ?? feedback.activity.trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
        return (name, feedback.outcomeTitle)
    }
    private var fillOpacity: Double {
        guard let feedback else { return 0 }
        if feedback.phase == .cancelled { return colorScheme == .dark ? 0.1 : 0.05 }
        return colorScheme == .dark ? 0.18 : 0.1
    }
    private var borderOpacity: Double {
        guard let feedback else { return 0 }
        if feedback.phase == .cancelled { return 0.28 }
        return colorScheme == .dark ? 0.44 : 0.3
    }
    private var showsTrailingDismiss: Bool {
        guard let feedback, feedback.phase != .running else { return false }
        return feedback.phase == .failed || feedback.warning != nil || hovering
    }
    private var helpText: String {
        guard let feedback else { return "" }
        if let progress {
            return feedback.title + " · " + progress.stage + " · " + progress.fraction.formatted(.percent.precision(.fractionLength(0)))
        }
        return feedback.title
    }

    var body: some View {
        Group {
            if let feedback {
                capsuleView(feedback)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    ))
            } else {
                Color.clear.frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86), value: feedback != nil)
        .background { ToolbarWindowWidthObserver(width: $windowWidth) }
        .onChange(of: store.snapshot?.root) { showingDetails = false }
        .onChange(of: feedback == nil) { if feedback == nil { showingDetails = false } }
        .confirmationDialog("Cancel the network operation?", isPresented: Binding(get: { pendingCancelID != nil }, set: { if !$0 { pendingCancelID = nil } })) {
            Button("Cancel Operation", role: .destructive) {
                if let pendingCancelID { store.networkActivity?.cancel(pendingCancelID) }
                pendingCancelID = nil
            }
        } message: {
            Text("Git or the server may already have changed. Review the refreshed state before retrying. Push and Pull are never retried automatically.")
        }
    }

    private func capsuleView(_ feedback: RepositoryOperationFeedback) -> some View {
        HStack(spacing: 6) {
            Button { showingDetails.toggle() } label: {
                HStack(spacing: 7) {
                    leadingIndicator
                    labelContent
                        .transaction { $0.animation = nil }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText)
            .accessibilityLabel("Activity")
            .accessibilityValue(Text(helpText))

            if let record = activeRecord {
                trailingActionButton(help: String(localized: "Cancel")) {
                    if record.command == "fetch" {
                        store.networkActivity?.cancel(record.id)
                    } else {
                        pendingCancelID = record.id
                    }
                }
            } else if showsTrailingDismiss {
                trailingActionButton(help: String(localized: "Dismiss")) {
                    store.dismissOperationFeedback(feedback.id)
                }
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, (activeRecord != nil || showsTrailingDismiss) ? 7 : 13)
        .frame(height: 34)
        .frame(maxWidth: capsuleMaxWidth)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .overlay {
                    Capsule().fill(statusTint.opacity(fillOpacity))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: feedback.phase)
                }
                .overlay {
                    Capsule().fill(Color.primary.opacity(hovering || showingDetails ? 0.05 : 0))
                }
        }
        .overlay(alignment: .bottom) {
            if isRunning {
                RepositoryProgressSweepBar(fraction: progress?.fraction, tint: statusTint, height: 2.5, reduceMotion: reduceMotion)
            }
        }
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(statusTint.opacity(borderOpacity), lineWidth: 0.75)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: feedback.phase)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.07), radius: 3, y: 1)
        .onHover { hovering = $0 }
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            RepositoryActivityDetailsView(store: store, close: { showingDetails = false })
        }
    }

    @ViewBuilder private var leadingIndicator: some View {
        if isRunning {
            if let progress {
                ZStack {
                    Circle()
                        .stroke(statusTint.opacity(colorScheme == .dark ? 0.34 : 0.24), lineWidth: 2.2)
                    Circle()
                        .trim(from: 0, to: max(0.08, progress.fraction))
                        .stroke(statusTint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: progress.fraction)
                }
                .frame(width: 15, height: 15)
                .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(statusTint)
                    .frame(width: 15, height: 15)
                    .accessibilityHidden(true)
            }
        } else {
            Image(systemName: statusSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusTint)
                .frame(width: 15, height: 15)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var labelContent: some View {
        let parts = splitActivity
        if isRunning, let progress {
            let percentText = progress.fraction.formatted(.percent.precision(.fractionLength(0)))
            if isCompactWidth {
                HStack(spacing: 5) {
                    Text(parts.primary)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(percentText)
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(percentColor)
                        .fixedSize()
                }
            } else {
                HStack(spacing: 5) {
                    Text(parts.primary)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("·")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                    Text(progress.stage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(percentText)
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(percentColor)
                        .fixedSize()
                }
            }
        } else if let detail = parts.detail {
            if isCompactWidth && isRunning {
                Text(parts.primary)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                HStack(spacing: 5) {
                    Text(parts.primary)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("·")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                    Text(detail)
                        .font(.system(size: 12, weight: isRunning ? .regular : .medium))
                        .foregroundStyle(isRunning ? AnyShapeStyle(.secondary) : AnyShapeStyle(statusTint))
                        .lineLimit(1)
                }
            }
        } else {
            Text(parts.primary)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private func trailingActionButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 19, height: 19)
                .background(Circle().fill(Color.primary.opacity(hoveringAction ? 0.14 : 0.07)))
        }
        .buttonStyle(.plain)
        .onHover { hoveringAction = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ToolbarWindowWidthObserver: NSViewRepresentable {
    @Binding var width: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(width: $width) }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onWindowChange = { window in context.coordinator.observe(window) }
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        context.coordinator.width = $width
        context.coordinator.observe(nsView.window)
    }

    @MainActor final class Coordinator {
        var width: Binding<CGFloat>
        private weak var observedWindow: NSWindow?
        private var token: NSObjectProtocol?

        init(width: Binding<CGFloat>) { self.width = width }

        isolated deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }

        func observe(_ window: NSWindow?) {
            guard window !== observedWindow else {
                if let window { publish(window.frame.width) }
                return
            }
            if let token { NotificationCenter.default.removeObserver(token); self.token = nil }
            observedWindow = window
            guard let window else { return }
            publish(window.frame.width)
            token = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
                Task { @MainActor in
                    guard let window else { return }
                    self?.publish(window.frame.width)
                }
            }
        }

        private func publish(_ value: CGFloat) {
            guard value > 0, abs(width.wrappedValue - value) > 0.5 else { return }
            Task { @MainActor [width] in
                guard abs(width.wrappedValue - value) > 0.5 else { return }
                width.wrappedValue = value
            }
        }
    }

    final class ObserverView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

struct RepositoryProgressSweepBar: View {
    let fraction: Double?
    let tint: Color
    var height: CGFloat = 2
    var reduceMotion: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                if let fraction {
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(width > 0 ? min(12, width) : 0, width * CGFloat(min(max(fraction, 0), 1))))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: fraction)
                } else if reduceMotion {
                    Capsule().fill(tint.opacity(0.45))
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let cycle = 1.35
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                        let normalized = phase < 0 ? phase + 1 : phase
                        let segmentWidth = max(24, width * 0.38)
                        let travel = width + segmentWidth
                        let offsetX = (CGFloat(normalized) * travel) - segmentWidth
                        Capsule()
                            .fill(LinearGradient(
                                colors: [.clear, tint.opacity(0.85), tint, tint.opacity(0.85), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: segmentWidth)
                            .offset(x: offsetX)
                    }
                }
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
