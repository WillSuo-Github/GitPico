import AppKit
import GitCore
import SwiftUI

struct BrowserFileRow: View {
    @Bindable var store: RepositoryStore
    let file: WorkingFileEntry
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.isIgnored ? "eye.slash" : "minus.square").foregroundStyle(.tertiary).frame(width: 14)
            Text(file.isIgnored ? "I" : file.assumeUnchanged ? "A" : file.skipWorktree ? "S" : "·").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 16)
            Image(systemName: "doc.text").foregroundStyle(.secondary).font(.system(size: 12))
            Text(file.path).font(.system(size: 12)).foregroundStyle(file.isIgnored ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }.frame(height: 22).contentShape(Rectangle()).help(file.status)
        .contextMenu {
            LFSFileContextMenu(store: store, path: file.path)
            if file.isIgnored { Button("Force Add Ignored Files…") { let paths = store.selectedWorkingFiles.contains(file.path) ? store.selectedWorkingFiles.filter { path in store.workingFileEntries.contains { $0.path == path && $0.isIgnored } }.sorted() : [file.path]; store.localChange(.forceAdd(paths)) } }
            if file.isTracked {
                Button("Show File History…") { store.navigate(.fileHistory(file.path, "HEAD")) }.disabled(store.snapshot?.hasHEAD != true)
                Button("Compare in External Tool…") { store.externalTool(.working(file.path, false)) }
            }
            Button("Open in Default Editor") { if let root = store.snapshot?.root { NSWorkspace.shared.open(root.appendingPathComponent(file.path)) } }
            Button("Reveal in Finder") { if let root = store.snapshot?.root { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(file.path)]) } }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string) }
        }.disabled(store.isBusy)
    }
}
struct WorkingFilePreview: View {
    let repository: GitRepository
    let path: String
    @State private var text = ""
    @State private var loading = true
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: path, subtitle: "Working Copy", icon: "doc.text")
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { InspectionTextView(text: text) }
        }.task {
            do {
                let data = try await repository.workingFileData(path)
                guard !Task.isCancelled else { return }
                let excerpt = data.prefix(256 * 1024)
                var preview: String?
                // Do not classify UTF-8 text as binary when the cap cuts a code point.
                for trim in 0...min(3, excerpt.count) {
                    if let value = String(data: excerpt.dropLast(trim), encoding: .utf8) { preview = value; break }
                }
                if !data.contains(0), let preview { text = preview + (data.count > 256 * 1024 ? "\n\n[Preview limited to 256 KB]" : "") }
                else { text = "Binary file · \(data.count) bytes. Open in an external editor to inspect it." }
            } catch { text = error.localizedDescription }
            loading = false
        }
    }
}
