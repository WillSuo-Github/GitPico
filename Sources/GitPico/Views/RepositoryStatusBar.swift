import AppKit
import SwiftUI

struct RepositoryStatusBar: View {
    static let height: CGFloat = 28
    @Bindable var store: RepositoryStore
    var body: some View {
        HStack(spacing: 10) {
            if store.isBusy {
                ProgressView().controlSize(.mini)
                Text(store.activity).foregroundStyle(.secondary)
            } else if let data = store.snapshot, !store.isChoosingRepository {
                Label(data.branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon).foregroundStyle(.primary)
                if data.ahead > 0 || data.behind > 0 {
                    HStack(spacing: 6) {
                        if data.ahead > 0 { Label("\(data.ahead)", systemImage: "arrow.up") }
                        if data.behind > 0 { Label("\(data.behind)", systemImage: "arrow.down") }
                    }.labelStyle(.titleAndIcon).foregroundStyle(.secondary).monospacedDigit()
                        .help("\(data.ahead) outgoing · \(data.behind) incoming commits")
                }
                separator
                Text(data.changes.isEmpty ? "Clean working copy" : "\(data.changes.count) changed \(data.changes.count == 1 ? "file" : "files")").foregroundStyle(.secondary)
            } else { Text("Ready to open a repository").foregroundStyle(.secondary) }
            Spacer(minLength: 12)
            Button { store.showingNetworkActivity = true } label: {
                Label(store.networkActivity?.runningCount ?? 0 > 0 ? "Network (\(store.networkActivity?.runningCount ?? 0))" : "Network", systemImage: store.networkActivity?.records.first?.phase == .failed ? "exclamationmark.icloud" : "network")
            }.buttonStyle(.borderless).help("Network progress, recent operations and authentication")
            if !store.conflictDrafts.isEmpty || store.conflictDraftSaveError != nil {
                Button { store.showingConflictDrafts = true } label: { Label("\(store.conflictDrafts.count) drafts", systemImage: store.conflictDraftSaveError == nil ? "doc.badge.clock" : "exclamationmark.triangle") }
                    .buttonStyle(.borderless).help(store.conflictDraftSaveError ?? "Recover saved conflict edits")
            }
            if let error = store.automaticRefreshError {
                Button { store.requestAutomaticRefresh() } label: { Image(systemName: "exclamationmark.arrow.circlepath") }
                    .buttonStyle(.borderless).help("Automatic refresh paused: " + error + "\nClick to retry.")
            }
            if let data = store.snapshot, !store.isChoosingRepository {
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: data.root.path)
                } label: {
                    Label(Pico.abbreviated(data.root.path), systemImage: "folder").lineLimit(1).truncationMode(.middle).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Open Repository in Finder\n" + data.root.path)
                .accessibilityLabel("Open Repository in Finder")
                .accessibilityValue(data.root.path)
                separator
                if let updated = store.lastUpdated {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Updated " + updated.formatted(.relative(presentation: .named))).foregroundStyle(.tertiary)
                    }
                }
                Button(action: store.refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(store.isBusy).help("Refresh (⌘R)").accessibilityLabel("Refresh")
            }
        }
        .font(.system(size: 11)).padding(.horizontal, 14).frame(height: Self.height)
        .background(.bar).overlay(alignment: .top) { Divider() }
    }
    private var separator: some View { Divider().frame(height: 12) }
}
