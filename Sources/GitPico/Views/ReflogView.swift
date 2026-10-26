import GitCore
import SwiftUI

struct ReflogView: View {
    @Bindable var store: RepositoryStore
    @State private var ref = "HEAD"
    @State private var entries: [ReflogEntry] = []
    @State private var selected: String?
    @State private var limit = 500
    @State private var error: String?
    var filtered: [ReflogEntry] { entries.filter { store.search.isEmpty || ($0.message + " " + $0.hash + " " + $0.name).localizedCaseInsensitiveContains(store.search) } }
    var body: some View {
        PersistentSplitView(name: "reflog", width: 320) {
            VStack(spacing: 0) {
                PaneBar(title: "Reflog", subtitle: "\(entries.count) events", icon: "list.bullet.rectangle") {
                    Picker("Reference", selection: $ref) {
                        Text("HEAD").tag("HEAD")
                        ForEach((store.snapshot?.references ?? []).filter { $0.isLocal || $0.isRemote }) { Text($0.name).tag($0.fullName) }
                    }.labelsHidden().frame(maxWidth: 150)
                }
                List(selection: $selected) {
                    ForEach(filtered) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: eventIcon(entry.message)).font(.system(size: 12, weight: .semibold)).foregroundStyle(eventColor(entry.message))
                                .frame(width: 26, height: 26).background(eventColor(entry.message).opacity(0.14), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(eventDetail(entry.message)).font(.system(size: 12.5, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 5) {
                                    Text(eventType(entry.message)).foregroundStyle(eventColor(entry.message)).fontWeight(.semibold)
                                    Text("·")
                                    Text(String(entry.hash.prefix(8))).font(.system(size: 10.5, design: .monospaced))
                                    Spacer(minLength: 0)
                                    Text(entry.date.picoRelative).fixedSize()
                                }.font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).tag(entry.id).help("\(entry.selector) · \(entry.name) <\(entry.email)>")
                            .accessibilityLabel("\(entry.selector), \(entry.hash.prefix(8)), \(entry.message), \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                            .contextMenu {
                                Button("Restore HEAD Here…") { store.recoveryRequest = RecoveryRequest(action: .restore(entry.hash)) }
                                Button("Create Branch Here…") { store.recoveryRequest = RecoveryRequest(action: .branch(entry.hash)) }
                            }
                    }
                    if entries.count == limit { Button("Load More Events") { limit += 500 } }
                }.listStyle(.plain)
                    .overlay { if let error { EmptyPane(title: "Unable to load Reflog", subtitle: error, icon: "exclamationmark.triangle") } else if filtered.isEmpty { EmptyPane(title: store.search.isEmpty ? "No reflog events" : "No matching events", subtitle: "Git records every local HEAD and branch movement here, so lost commits can be recovered.", icon: "list.bullet.rectangle") } }
            }
        } trailing: {
            CommitDetailView(store: store)
        }
        .task(id: "\(ref):\(limit):\(store.lastUpdated?.timeIntervalSince1970 ?? 0)") {
            guard let repository = store.repository else { return }
            do {
                let values = try await repository.reflog(ref: ref, limit: limit)
                guard !Task.isCancelled else { return }
                entries = values; error = nil
                if !values.contains(where: { $0.id == selected }) { selected = values.first?.id }
                await selectEntry()
            } catch { self.error = error.localizedDescription }
        }
        .task(id: selected) { await selectEntry() }
    }
    func selectEntry() async {
        guard let repository = store.repository, let entry = entries.first(where: { $0.id == selected }) else { return }
        do { let commit = try await repository.commit(at: entry.hash); guard !Task.isCancelled, selected == entry.id else { return }; store.selectCommit(commit) }
        catch { self.error = error.localizedDescription }
    }
    func eventType(_ message: String) -> String { String(message.split(separator: ":").first?.split(separator: " ").first ?? "event") }
    func eventColor(_ message: String) -> Color {
        switch eventType(message) {
        case "rebase": .purple
        case "commit": Pico.addition
        case "merge": Pico.modified
        case "reset": Pico.deletion
        case "checkout": .teal
        case "pull", "fetch": .indigo
        default: .secondary
        }
    }
    func eventIcon(_ message: String) -> String {
        switch eventType(message) {
        case "rebase": "arrow.triangle.swap"
        case "commit": "plus"
        case "merge": "arrow.triangle.merge"
        case "reset": "arrow.uturn.backward"
        case "checkout": "arrow.triangle.branch"
        case "pull", "fetch": "arrow.down"
        case "cherry-pick": "arrow.right.doc.on.clipboard"
        default: "circle"
        }
    }
    /// Message without its "type:" prefix, which the row already shows as a label.
    func eventDetail(_ message: String) -> String {
        guard let colon = message.firstIndex(of: ":") else { return message }
        let rest = message[message.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? message : rest.prefix(1).uppercased() + rest.dropFirst()
    }
}
