import AppKit
import GitCore
import SwiftUI

struct NetworkActivityView: View {
    @Bindable var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { SheetTitle("Network Activity", icon: "network"); Spacer(); Button("Authentication…") { store.authenticationAfterNetwork = true; dismiss() } }
            if let activity = store.networkActivity {
                if let error = activity.storageError { Text("Activity history could not be saved: \(error)").font(.caption).foregroundStyle(Pico.warning) }
                HSplitView {
                    List(activity.records, selection: $selection) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: symbol(record.phase)).foregroundStyle(tint(record.phase))
                                Text(networkCommandTitle(record.command)).fontWeight(.medium)
                                Spacer()
                                if record.phase == .running { ProgressView().controlSize(.mini) }
                            }
                            Text("\(record.repository) · \(record.started.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
                            Text(record.phase.title).font(.caption2).foregroundStyle(tint(record.phase))
                        }.padding(.vertical, 4).tag(record.id)
                    }.frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
                    if let record = activity.records.first(where: { $0.id == selection }) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(networkCommandTitle(record.command)).font(.headline)
                                Spacer()
                                if record.phase == .running { Button("Cancel…") { cancelling = record.id } }
                                Button("Copy Log") { Pico.copy(record.output) }
                            }
                            if record.phase == .running {
                                if let progress = record.progress { ProgressView(value: progress).help("Git's current phase: \(Int(progress * 100))%") }
                                else { ProgressView() }
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text("Running for \(Int(context.date.timeIntervalSince(record.started))) seconds").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if record.phase == .failed || record.phase == .cancelled {
                                Text(networkFailureAdvice(record.output)).font(.callout).foregroundStyle(Pico.warning)
                                if record.command == "fetch", record.repositoryPath == store.snapshot?.root.path { Button("Fetch All Remotes Again") { store.sync(.fetch) }.disabled(!store.canUseRepository) }
                            }
                            ScrollView([.horizontal, .vertical]) { Text(record.output.isEmpty ? String(localized: "No output was returned.") : record.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }.padding(12).frame(minWidth: 380)
                    } else { EmptyPane(title: String(localized: "Network activity"), subtitle: String(localized: "Select an operation to inspect its progress and output."), icon: "network").frame(minWidth: 380) }
                }.frame(minHeight: 350)
                HStack { Button("Clear Completed", action: activity.clearCompleted); Spacer(); Text("Recent 100 operations · credentials and URLs are redacted").font(.caption).foregroundStyle(.secondary) }
            } else { EmptyPane(title: String(localized: "No network activity yet"), subtitle: String(localized: "Open a repository or clone one to get started."), icon: "network").frame(height: 300) }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 820)
            .onAppear { selection = store.networkActivity?.records.first?.id }
            .onChange(of: store.networkActivity?.records.first?.id) { if selection == nil { selection = store.networkActivity?.records.first?.id } }
            .confirmationDialog("Cancel the network operation?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } })) {
                Button("Cancel Operation", role: .destructive) { if let cancelling { store.networkActivity?.cancel(cancelling) }; cancelling = nil }
            } message: { Text("Git or the server may already have changed. Review the refreshed state before retrying. Push and Pull are never retried automatically.") }
    }
    @State private var cancelling: UUID?
    private func symbol(_ phase: GitNetworkEvent.Phase) -> String { switch phase { case .running: "arrow.triangle.2.circlepath"; case .succeeded: "checkmark.circle"; case .failed: "exclamationmark.circle"; case .cancelled: "stop.circle" } }
    private func tint(_ phase: GitNetworkEvent.Phase) -> Color { switch phase { case .running: .accentColor; case .succeeded: Pico.addition; case .failed: Pico.deletion; case .cancelled: .secondary } }
}

func networkFailureAdvice(_ output: String) -> String {
    let value = output.lowercased()
    if value.contains("authentication") || value.contains("401") || value.contains("403") || value.contains("permission denied") { return String(localized: "Check the selected account, token permissions or unlocked SSH keys in Authentication.") }
    if value.contains("host key verification") { return String(localized: "Verify the SSH host fingerprint with your hosting service, then trust it using your system SSH setup. GitPico does not bypass host verification.") }
    if value.contains("resolve host") || value.contains("timed out") || value.contains("unable to access") { return String(localized: "Check the network, proxy and server address. Retry Fetch when the connection is available.") }
    if value.contains("non-fast-forward") || value.contains("fetch first") || value.contains("divergent") || value.contains("diverging") || value.contains("not possible to fast-forward") { return String(localized: "Fetch and review incoming changes. Open Pull to choose Merge or Rebase deliberately; do not force-push to bypass this error.") }
    return String(localized: "Inspect the repository and remote state before retrying. A cancelled or failed write can have partially completed.")
}
