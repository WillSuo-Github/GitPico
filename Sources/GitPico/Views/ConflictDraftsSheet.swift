import AppKit
import SwiftUI

struct ConflictDraftsSheet: View {
    @Bindable var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var discarding: String?
    @State private var exportError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle("Conflict Drafts", icon: "doc.badge.clock")
            Text("Saved edits are kept even if Git resolves or removes the conflict elsewhere. Copy or export them before discarding.").font(.callout).foregroundStyle(.secondary)
            if let error = store.conflictDraftSaveError { Text(error).foregroundStyle(Pico.deletion).font(.caption) }
            HSplitView {
                List(store.conflictDrafts.keys.sorted(), id: \.self, selection: $selection) { path in Text(path).lineLimit(2).tag(path) }.frame(minWidth: 200, idealWidth: 240, maxWidth: 280)
                ScrollView([.horizontal, .vertical]) {
                    Text(selection.flatMap { store.conflictDrafts[$0]?.text } ?? String(localized: "Select a saved draft"))
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
                }.frame(minWidth: 360)
            }.frame(minHeight: 300)
            if let exportError { Text(exportError).foregroundStyle(Pico.deletion).font(.caption) }
            HStack {
                if let selection, let draft = store.conflictDrafts[selection] {
                    Button("Copy Draft") { Pico.copy(draft.text) }
                    Button("Export…") { export(draft.text, path: selection) }
                    Button("Discard Draft…", role: .destructive) { discarding = selection }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(22).frame(width: 760)
            .onAppear { selection = store.conflictDrafts.keys.sorted().first }
            .confirmationDialog("Discard this saved conflict draft?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
                Button("Discard Draft", role: .destructive) {
                    if let discarding { store.conflictDrafts.removeValue(forKey: discarding) }
                    discarding = nil; selection = store.conflictDrafts.keys.sorted().first
                }
            }
    }
    private func export(_ text: String, path: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: path).lastPathComponent + ".draft.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(text.utf8).write(to: url, options: .withoutOverwriting) }
            catch { exportError = error.localizedDescription }
        }
    }
}
