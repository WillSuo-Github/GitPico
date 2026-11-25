import AppKit
import SwiftUI

struct RepositoryStatusBar: View {
    static let height: CGFloat = 28
    @Bindable var store: RepositoryStore
    var showsBackground = true
    var showsConflictDrafts: Bool { store.showsRepositoryStatus && (!store.conflictDrafts.isEmpty || store.conflictDraftSaveError != nil) }
    var showsAutomaticRefreshError: Bool { store.showsRepositoryStatus && store.automaticRefreshError != nil }

    var body: some View {
        HStack(spacing: 10) {
            if let data = store.snapshot, !store.isChoosingRepository {
                if store.isLinkedWorktree, let current = store.currentWorktree {
                    Label("Worktree", systemImage: "folder.badge.gearshape").foregroundStyle(.tint).help(current.path)
                    separator
                }
                Label(data.branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
                if data.ahead > 0 || data.behind > 0 {
                    HStack(spacing: 6) {
                        if data.ahead > 0 { Label("\(data.ahead)", systemImage: "arrow.up") }
                        if data.behind > 0 { Label("\(data.behind)", systemImage: "arrow.down") }
                    }.labelStyle(.titleAndIcon).foregroundStyle(.secondary).monospacedDigit()
                        .help("\(data.ahead) outgoing · \(data.behind) incoming commits")
                }
                separator
                Text(data.changes.isEmpty ? "Clean working copy" : "\(data.changes.count) changed files").foregroundStyle(.secondary)
            } else if let clone = store.cloneSession {
                Text(cloneStatusText(for: clone)).foregroundStyle(.secondary)
            } else if store.isBusy, !store.activity.isEmpty {
                Text(store.activity).foregroundStyle(.secondary)
            } else { Text("Ready to open a repository").foregroundStyle(.secondary) }
            Spacer(minLength: 12)
            if let data = store.snapshot, !store.isChoosingRepository {
                if showsConflictDrafts {
                    Button { store.showingConflictDrafts = true } label: { Label("\(store.conflictDrafts.count) drafts", systemImage: store.conflictDraftSaveError == nil ? "doc.badge.clock" : "exclamationmark.triangle").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).help(store.conflictDraftSaveError ?? String(localized: "Recover saved conflict edits"))
                }
                if showsAutomaticRefreshError, let error = store.automaticRefreshError {
                    Button { store.requestAutomaticRefresh() } label: { Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless).help("Automatic refresh paused: \(error)\nClick to retry.")
                }
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: data.root.path)
                } label: {
                    Label(Pico.abbreviated(data.root.path), systemImage: "folder").lineLimit(1).truncationMode(.middle).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Open Repository in Finder\n\(data.root.path)")
                .accessibilityLabel("Open Repository in Finder")
                .accessibilityValue(data.root.path)
                separator
                if let updated = store.lastUpdated {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Updated \(updated.formatted(.relative(presentation: .named)))").foregroundStyle(.tertiary)
                    }.fixedSize()
                }
            }
            RepositoryActivityButton(store: store)
            if store.snapshot != nil, !store.isChoosingRepository {
                Button(action: store.refresh) { Image(systemName: "arrow.clockwise").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless).disabled(store.isBusy).help("Refresh (⌘R)").accessibilityLabel("Refresh")
            }
        }
        .font(.system(size: 11)).lineLimit(1).padding(.horizontal, 14).frame(height: Self.height)
        .background {
            Color.clear.contentShape(Rectangle()).onTapGesture {}.accessibilityHidden(true)
        }
        .background {
            if showsBackground { RepositoryStatusBarBackground(isRunning: store.isPerformingStatusActivity) }
        }
    }
    private var separator: some View { Divider().frame(height: 12) }

    private func cloneStatusText(for session: RepositoryCloneSession) -> String {
        switch session.phase {
        case .cloning:
            return session.isCancelling ? String(localized: "Cancelling clone…") : String(localized: "Cloning \(session.name)…")
        case .opening:
            return String(localized: "Opening \(session.name)…")
        case .cancelled:
            return String(localized: "Clone cancelled")
        case .failed:
            return String(localized: "Clone failed")
        }
    }
}
