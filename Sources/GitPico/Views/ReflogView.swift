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
                HStack {
                    Picker("Ref:", selection: $ref) {
                        Text("HEAD").tag("HEAD")
                        ForEach((store.snapshot?.references ?? []).filter { $0.isLocal || $0.isRemote }) { Text($0.name).tag($0.fullName) }
                    }.pickerStyle(.menu)
                    Spacer(minLength: 0)
                    Text("\(entries.count) events").foregroundStyle(.secondary)
                }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 40).background(.bar)
                Divider()
                List(selection: $selected) {
                    ForEach(filtered) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                Text(String(entry.hash.prefix(8))).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                Text(eventType(entry.message)).font(.system(size: 10, weight: .medium)).padding(.horizontal, 4).padding(.vertical, 2).foregroundStyle(.white).background(eventColor(entry.message).opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                                Spacer(minLength: 0)
                                Text(entry.date, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute()).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize()
                            }
                            Text(entry.message).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 8).tag(entry.id).help("\(entry.selector) · \(entry.name) <\(entry.email)>")
                            .accessibilityLabel("\(entry.selector), \(entry.hash.prefix(8)), \(entry.message), \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                            .contextMenu {
                                Button("Restore HEAD Here…") { store.recoveryRequest = RecoveryRequest(action: .restore(entry.hash)) }
                                Button("Create Branch Here…") { store.recoveryRequest = RecoveryRequest(action: .branch(entry.hash)) }
                            }
                    }
                    if entries.count == limit { Button("Load More Events") { limit += 500 } }
                }.listStyle(.plain)
                    .overlay { if let error { EmptyPane(title: "Unable to load Reflog", subtitle: error, icon: "exclamationmark.triangle") } else if filtered.isEmpty { EmptyPane(title: "No reflog events", subtitle: "Reference movements are recorded locally by Git.", icon: "clock") } }
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
    func eventColor(_ message: String) -> Color { switch eventType(message) { case "rebase": .red; case "commit": .yellow; case "merge": .blue; default: .gray } }
}
