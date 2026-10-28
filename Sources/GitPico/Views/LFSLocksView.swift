import GitCore
import SwiftUI

struct LFSLocksView: View {
    let store: RepositoryStore
    @State private var remote = ""
    @State private var remotes: [RemoteConfiguration] = []
    @State private var locks: [LFSFileLock] = []
    @State private var path = ""
    @State private var plan: LFSLockPlan?
    @State private var busy = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { SheetTitle("LFS Server Locks", icon: "lock"); Spacer(); Picker("Remote", selection: $remote) { ForEach(remotes) { Text($0.name).tag($0.name) } }.frame(width: 160).disabled(busy); Button("Reload") { Task { await reload() } }.disabled(busy) }
            Text("Server locks coordinate binary-file editing. Your configured LFS endpoint and selected HTTPS account or system SSH setup are used.").font(.caption).foregroundStyle(.secondary)
            HStack { TextField("Repository-relative file path", text: $path); Button("Lock…") { prepare(.lock(path)) }.disabled(path.isEmpty || busy) }
            if let message { Text(message).font(.caption).foregroundStyle(Pico.warning).textSelection(.enabled) }
            if busy { ProgressView().controlSize(.small) }
            List(locks) { lock in
                HStack {
                    VStack(alignment: .leading, spacing: 3) { Text(lock.path); Text(verbatim: lock.owner.name + " · " + (lock.locked_at ?? String(localized: "Unknown date"))).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("Unlock…") { prepare(.unlock(lock, force: false)) }
                    Menu { Button("Force Unlock…", role: .destructive) { prepare(.unlock(lock, force: true)) } } label: { Image(systemName: "ellipsis.circle") }
                }.disabled(busy)
            }.frame(height: 350)
            Text("Up to 1000 server locks are shown. Reload after an interrupted request before retrying; the server may already have applied it.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 760).task { await reload() }
        .onChange(of: remote) { if !busy { locks = []; plan = nil; Task { await reload() } } }
        .confirmationDialog(plan?.action.title ?? String(localized: "LFS Lock"), isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } })) {
            if let captured = plan { Button(captured.action.title, role: isForce(captured) ? .destructive : nil) { plan = nil; execute(captured) } }
        } message: {
            if let plan { Text(confirmationMessage(plan)) }
        }
    }
    private func isForce(_ plan: LFSLockPlan) -> Bool { if case .unlock(_, true) = plan.action { true } else { false } }
    private func confirmationMessage(_ plan: LFSLockPlan) -> String {
        let question = String(localized: "\(plan.action.title) “\(plan.action.path)” on “\(plan.remote)”?")
        return isForce(plan) ? String(localized: "\(question) This may remove another person's lock.") : question
    }
    private func prepare(_ action: LFSLockAction) {
        guard let repository = store.repository else { return }
        busy = true
        Task { defer { busy = false }; do { store.configureNetworkContext(); plan = try await repository.previewLFSLock(action, remote: remote) } catch { message = error.localizedDescription } }
    }
    private func execute(_ plan: LFSLockPlan) {
        guard let repository = store.repository else { return }
        busy = true
        Task {
            do { try await repository.runLFSLock(plan); message = String(localized: "Server lock operation completed.") }
            catch { message = GitLogRedaction.clean(error.localizedDescription) }
            busy = false; await reload()
        }
    }
    private func reload() async {
        guard !busy, let repository = store.repository else { return }
        busy = true; defer { busy = false }
        do {
            remotes = try await repository.remoteConfigurations()
            if remote.isEmpty { remote = remotes.first(where: { $0.name == "origin" })?.name ?? remotes.first?.name ?? "" }
            store.configureNetworkContext(); locks = try await repository.lfsLocks(remote: remote)
        } catch { message = GitLogRedaction.clean(error.localizedDescription) }
    }
}
