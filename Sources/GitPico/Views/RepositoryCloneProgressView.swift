import AppKit
import GitCore
import SwiftUI

struct RepositoryCloneProgressView: View {
    let store: RepositoryStore
    let session: RepositoryCloneSession
    @State private var showingOutput = false
    @State private var copiedOutput = false
    @State private var entered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.repositoryStatusMotionEnabled) private var motionEnabled

    private var reduceMotion: Bool { systemReduceMotion || !motionEnabled }
    private var isFailed: Bool { session.failureMessage != nil }
    private var isCancelled: Bool { session.phase == .cancelled }

    private var statusBadgeTitle: String {
        switch session.phase {
        case .cloning: return session.isCancelling ? String(localized: "Cancelling") : String(localized: "Cloning")
        case .opening: return String(localized: "Opening")
        case .cancelled: return String(localized: "Cancelled")
        case .failed: return String(localized: "Failed")
        }
    }

    private var statusTint: Color {
        switch session.phase {
        case .cloning: return .accentColor
        case .opening: return Pico.addition
        case .cancelled: return .secondary
        case .failed: return Pico.deletion
        }
    }

    private var glyphBadgeIcon: String {
        switch session.phase {
        case .cloning: return "arrow.down"
        case .opening: return "checkmark"
        case .cancelled: return "stop.fill"
        case .failed: return "exclamationmark"
        }
    }

    private var sourceIcon: String {
        let trimmed = session.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.lowercased().hasPrefix("file://") {
            return "externaldrive"
        }
        return "cloud"
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 24)
                    VStack(alignment: .leading, spacing: 18) {
                        header
                            .staggeredEntrance(isShowing: entered, index: 0, style: .hero)
                        progressCard
                            .staggeredEntrance(isShowing: entered, index: 1, style: .hero)
                        outputCard
                            .staggeredEntrance(isShowing: entered, index: 2, style: .hero)
                        footer
                            .staggeredEntrance(isShowing: entered, index: 3, style: .hero)
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 36)
                .padding(.top, 20)
                .padding(.bottom, 20)
                .frame(minHeight: geometry.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                stops: [.init(color: Pico.brandTop.opacity(0.10), location: 0), .init(color: .clear, location: 0.32)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
        }
        .safeAreaPadding(.bottom)
        .staggeredEntranceTrigger($entered, id: session.id)
        .onAppear {
            if isFailed { showingOutput = true }
        }
        .onChange(of: session.id) {
            showingOutput = isFailed
            copiedOutput = false
        }
        .onChange(of: isFailed) { _, failed in
            if failed { showingOutput = true }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                RepositoryGlyph(name: session.name, size: 48)
                Image(systemName: glyphBadgeIcon)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(statusTint, in: Circle())
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .offset(x: 4, y: 4)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(session.name)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Chip(text: statusBadgeTitle, tint: statusTint)
                    if session.recursive {
                        Chip(text: String(localized: "Submodules"), icon: "shippingbox", tint: .secondary)
                    }
                    if session.lfs != .inherit {
                        Chip(
                            text: session.lfs == .pointersOnly ? String(localized: "LFS Pointers") : String(localized: "Git LFS"),
                            icon: "externaldrive",
                            tint: .secondary
                        )
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: sourceIcon)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Text(session.displaySource)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(session.displaySource)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Text(Pico.abbreviated(session.destination.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(session.destination.path)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            elapsedBadge
        }
    }

    @ViewBuilder private var elapsedBadge: some View {
        if session.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                durationPill(elapsed: max(0, context.date.timeIntervalSince(session.started)))
            }
        } else {
            durationPill(elapsed: max(0, (session.finished ?? Date()).timeIntervalSince(session.started)))
        }
    }

    private func durationPill(elapsed: TimeInterval) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 10))
            Text(Self.formatDuration(elapsed))
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
        .fixedSize()
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            stageRail
            Divider().opacity(0.6)
            activeStageSummary
            if session.isRunning {
                RepositoryProgressSweepBar(
                    fraction: session.phase == .opening ? nil : session.transferProgress?.fraction,
                    tint: .accentColor,
                    height: 6,
                    reduceMotion: reduceMotion
                )
            } else {
                outcomeCallout
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.03), radius: 8, y: 2)
    }

    private var stageRail: some View {
        let steps = RepositoryCloneSession.Step.allCases
        return HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                let state = stepState(for: step)
                VStack(spacing: 7) {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(index == 0 ? Color.clear : connectorColor(before: step))
                            .frame(height: 1.5)
                        stepNode(state: state)
                        Rectangle()
                            .fill(index == steps.count - 1 ? Color.clear : connectorColor(after: step))
                            .frame(height: 1.5)
                    }
                    Text(step.title)
                        .font(.system(size: 11, weight: state == .active ? .semibold : .medium))
                        .foregroundStyle(stepLabelColor(for: state))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Clone stages"))
        .accessibilityValue(session.activeStep.title)
    }

    private enum StepVisualState {
        case completed, active, failed, cancelled, pending
    }

    private func stepState(for step: RepositoryCloneSession.Step) -> StepVisualState {
        let current = session.activeStep
        if step < current { return .completed }
        if step > current { return .pending }
        switch session.phase {
        case .cloning, .opening: return .active
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    private func connectorColor(before step: RepositoryCloneSession.Step) -> Color {
        step <= session.activeStep ? Pico.addition.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.65)
    }

    private func connectorColor(after step: RepositoryCloneSession.Step) -> Color {
        step < session.activeStep ? Pico.addition.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.65)
    }

    private func stepLabelColor(for state: StepVisualState) -> Color {
        switch state {
        case .completed: return .secondary
        case .active: return .primary
        case .failed: return Pico.deletion
        case .cancelled: return .secondary
        case .pending: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    @ViewBuilder private func stepNode(state: StepVisualState) -> some View {
        switch state {
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Pico.addition, in: Circle())
        case .active:
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.18))
                    .frame(width: 22, height: 22)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 20, height: 20)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Pico.deletion, in: Circle())
        case .cancelled:
            Image(systemName: "stop.fill")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.secondary, in: Circle())
        case .pending:
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(colorScheme == .dark ? 0.45 : 0.35), lineWidth: 1.25))
                .frame(width: 20, height: 20)
        }
    }

    private var activeStageSummary: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(session.headline)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isFailed ? Pico.deletion : .primary)
                    if session.isRunning, let submodule = session.activeSubmodule {
                        Chip(text: submodule, icon: "shippingbox", tint: .secondary)
                    }
                }
                Text(session.subheadline)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(session.isRunning ? 1 : 2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 10)
            if session.isRunning {
                if session.phase == .cloning, let progress = session.transferProgress {
                    let percentText = Text("\(progress.percent)%")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    if reduceMotion {
                        percentText
                    } else {
                        percentText.contentTransition(.numericText())
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text(session.headline))
                }
            } else {
                Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "stop.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(isFailed ? Pico.deletion : .secondary)
            }
        }
    }

    @ViewBuilder private var outcomeCallout: some View {
        let tint: Color = isFailed ? Pico.deletion : .secondary
        let advice = session.failureMessage.map { message in
            networkFailureAdvice(session.output.isEmpty ? message : session.output, timedOut: session.timedOut)
        } ?? String(localized: "You can go back to your repositories or adjust options to start again.")
        VStack(alignment: .leading, spacing: 6) {
            Text(advice)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if session.destinationExistsOnDisk {
                Text("Existing files in \(Pico.abbreviated(session.destination.path)) were kept untouched. Choose a new folder name or remove the partial folder before cloning into the same path.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(colorScheme == .dark ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if reduceMotion {
                        showingOutput.toggle()
                    } else {
                        withAnimation(.easeInOut(duration: 0.16)) { showingOutput.toggle() }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showingOutput ? 90 : 0))
                            .frame(width: 10)
                        Image(systemName: "terminal")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Git Output")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        if !showingOutput {
                            Text(session.latestOutputLine ?? String(localized: "Waiting for Git output…"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showingOutput ? String(localized: "Hide Git Output") : String(localized: "Show Git Output"))

                if !session.output.isEmpty {
                    Button {
                        Pico.copy(session.output)
                        copiedOutput = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copiedOutput = false
                        }
                    } label: {
                        Label(copiedOutput ? "Copied" : "Copy Log", systemImage: copiedOutput ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(copiedOutput ? Pico.addition : .secondary)
                    }
                    .buttonStyle(.borderless)
                }
                if session.networkRecordID != nil {
                    Button("Network Activity") { store.inspectOperationNetworkActivity() }
                        .font(.system(size: 11))
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showingOutput {
                Divider().opacity(0.6)
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(session.output.isEmpty ? String(localized: "Waiting for Git output…") : session.output)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(session.output.isEmpty ? .tertiary : .secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            Color.clear
                                .frame(height: 1)
                                .id("clone-output-bottom")
                        }
                        .padding(12)
                    }
                    .frame(height: 176)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.85))
                    .onChange(of: session.output) {
                        proxy.scrollTo("clone-output-bottom", anchor: .bottom)
                    }
                    .onAppear {
                        proxy.scrollTo("clone-output-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if session.isRunning {
                Label("Repository opens automatically when finished", systemImage: "arrow.right.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Cancel Clone") { store.cancelActiveClone() }
                    .disabled(!session.canCancel)
            } else {
                Button("Back to Repositories") { store.dismissCloneSession() }
                if session.destinationExistsOnDisk {
                    Button("Reveal Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([session.destination])
                    }
                }
                if session.isAuthenticationFailure {
                    Button("Authentication…") { store.showingAuthentication = true }
                }
                Spacer(minLength: 12)
                if session.destinationExistsOnDisk {
                    Button("Edit Options…") { store.editCloneSession() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Edit Options…") { store.editCloneSession() }
                    Button("Retry Clone") { store.retryCloneSession() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
