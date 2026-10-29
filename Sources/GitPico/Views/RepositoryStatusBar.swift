import AppKit
import SwiftUI

struct RepositoryStatusBar: View {
    static let height: CGFloat = 28
    @Bindable var store: RepositoryStore
    @Environment(\.colorScheme) private var colorScheme

    private var runningAccent: NSColor {
        var color = NSColor.controlAccentColor
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemPurple
        }
        return color
    }
    private var runningForeground: Color {
        let color = runningAccent
        let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { value in
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        return 1.05 / (luminance + 0.05) >= (luminance + 0.05) / 0.05 ? .white : .black
    }
    private var primary: Color { store.isBusy ? runningForeground : .primary }
    private var secondary: Color { store.isBusy ? runningForeground.opacity(0.9) : .secondary }
    private var tertiary: Color { store.isBusy ? runningForeground.opacity(0.8) : Color(nsColor: .tertiaryLabelColor) }

    var body: some View {
        HStack(spacing: 10) {
            if store.isBusy {
                ProgressView().controlSize(.mini).tint(primary)
                let feedback = store.operationFeedback.flatMap { $0.phase == .running ? $0 : nil }
                let title = feedback?.title ?? store.activity
                Text(title).fontWeight(.semibold).foregroundStyle(primary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1).help(title)
                if let feedback {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(max(0, Int(context.date.timeIntervalSince(feedback.started))))s")
                            .monospacedDigit().foregroundStyle(secondary)
                    }.fixedSize()
                }
            } else if let feedback = store.operationFeedback, feedback.isVisible, !store.isChoosingRepository {
                RepositoryOperationFeedbackView(store: store)
            } else if let data = store.snapshot, !store.isChoosingRepository {
                Label(data.branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon).foregroundStyle(primary)
                if data.ahead > 0 || data.behind > 0 {
                    HStack(spacing: 6) {
                        if data.ahead > 0 { Label("\(data.ahead)", systemImage: "arrow.up") }
                        if data.behind > 0 { Label("\(data.behind)", systemImage: "arrow.down") }
                    }.labelStyle(.titleAndIcon).foregroundStyle(secondary).monospacedDigit()
                        .help("\(data.ahead) outgoing · \(data.behind) incoming commits")
                }
                separator
                Text(data.changes.isEmpty ? "Clean working copy" : "\(data.changes.count) changed files").foregroundStyle(secondary)
            } else { Text("Ready to open a repository").foregroundStyle(secondary) }
            Spacer(minLength: 12)
            Button { store.showingNetworkActivity = true } label: {
                Label(store.networkActivity?.runningCount ?? 0 > 0 ? "Network (\(store.networkActivity?.runningCount ?? 0))" : "Network", systemImage: store.networkActivity?.records.first?.phase == .failed ? "exclamationmark.icloud" : "network")
                    .foregroundStyle(secondary)
            }.buttonStyle(.borderless).help("Network progress, recent operations and authentication")
            if !store.conflictDrafts.isEmpty || store.conflictDraftSaveError != nil {
                Button { store.showingConflictDrafts = true } label: { Label("\(store.conflictDrafts.count) drafts", systemImage: store.conflictDraftSaveError == nil ? "doc.badge.clock" : "exclamationmark.triangle").foregroundStyle(secondary) }
                    .buttonStyle(.borderless).help(store.conflictDraftSaveError ?? String(localized: "Recover saved conflict edits"))
            }
            if let error = store.automaticRefreshError {
                Button { store.requestAutomaticRefresh() } label: { Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(secondary) }
                    .buttonStyle(.borderless).help("Automatic refresh paused: \(error)\nClick to retry.")
            }
            if let data = store.snapshot, !store.isChoosingRepository {
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: data.root.path)
                } label: {
                    Label(Pico.abbreviated(data.root.path), systemImage: "folder").lineLimit(1).truncationMode(.middle).foregroundStyle(tertiary)
                }
                .buttonStyle(.plain)
                .help("Open Repository in Finder\n\(data.root.path)")
                .accessibilityLabel("Open Repository in Finder")
                .accessibilityValue(data.root.path)
                separator
                if let updated = store.lastUpdated {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Updated \(updated.formatted(.relative(presentation: .named)))").foregroundStyle(tertiary)
                    }.fixedSize()
                }
                Button(action: store.refresh) { Image(systemName: "arrow.clockwise").foregroundStyle(secondary) }
                    .buttonStyle(.borderless).disabled(store.isBusy).help("Refresh (⌘R)").accessibilityLabel("Refresh")
            }
        }
        .font(.system(size: 11)).padding(.horizontal, 14).frame(height: Self.height)
        .background {
            if store.isBusy { Color(nsColor: runningAccent) }
            else { Rectangle().fill(.bar) }
        }
        .overlay(alignment: .top) { Divider() }
    }
    private var separator: some View { Divider().frame(height: 12).overlay { if store.isBusy { primary.opacity(0.3) } } }
}
