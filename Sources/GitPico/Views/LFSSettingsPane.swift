import GitCore
import SwiftUI

struct LFSSettingsPane: View {
    @Bindable var store: RepositoryStore
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack {
                    SheetTitle("Git LFS", icon: "externaldrive"); Spacer()
                    Button("Server Locks…") { store.showingLFSLocks = true }.disabled(store.isBusy)
                    Button("Reload") { Task { await store.loadLFS() } }.disabled(store.isBusy)
                }
                if let state = store.lfsState {
                    Text(state.version).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(state.enabled ? "Enabled for this repository" : "LFS filters are not enabled").fontWeight(.medium)
                        Spacer()
                        Button(state.enabled ? "Disable Locally…" : "Enable Git LFS…") { store.manageLFS(.change(state.enabled ? .disable : .enable(installHook: true))) }.disabled(!state.available || store.isBusy)
                    }
                    Text(state.hookInstalled ? "LFS pre-push hook detected." : "LFS pre-push hook not detected. Existing custom hooks are preserved; integrate git lfs pre-push when needed.").font(.caption).foregroundStyle(.secondary)
                    if state.available {
                        HStack { Text("TRACKING PATTERNS").font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Button("Create Tracking Pattern…") { store.manageLFS(.change(.track("", filename: false, source: ".gitattributes"))) } }
                        VStack(spacing: 0) {
                            ForEach(state.rules) { rule in
                                HStack { Image(systemName: "doc.badge.gearshape"); VStack(alignment: .leading) { Text(rule.pattern).font(.system(size: 12, design: .monospaced)); Text(rule.source + (rule.lockable ? " · Lockable" : "") + (rule.tracked ? "" : " · Excluded")).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Remove…") { store.manageLFS(.change(.untrack(rule.relativePattern, source: rule.source))) } }.padding(8)
                                Divider()
                            }
                            if state.rules.isEmpty { Text("No LFS tracking patterns.").foregroundStyle(.secondary).padding(12) }
                        }.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
                        Button("Stage Existing Files with LFS…") { store.manageLFS(.renormalize([])) }.disabled(store.isBusy || !state.enabled)
                        Text("Stage and commit .gitattributes yourself. Tracking patterns affect future staging; committed history is not rewritten. Existing normal Git files need an explicit re-stage to convert.").font(.caption).foregroundStyle(.secondary)
                        HStack { Text("LFS OBJECTS · \(state.files.count)").font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Menu("Transfer") { ForEach(LFSTransfer.allCases, id: \.self) { operation in Button(operation.rawValue + "…") { store.manageLFS(.transfer(operation)) } } } }.disabled(!state.enabled || store.isBusy)
                        ForEach(state.files) { file in
                            HStack { Image(systemName: file.checkout ? "doc.fill" : "doc"); VStack(alignment: .leading, spacing: 3) { Text(file.name).font(.system(size: 12)); Text(String(file.oid.prefix(12)) + " · " + ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file)).font(.caption.monospaced()).foregroundStyle(.secondary) }; Spacer(); Text(file.downloaded ? (file.checkout ? "Checked out" : "Cached") : "Pointer / Missing").font(.caption).foregroundStyle(.secondary) }
                        }
                        if state.files.isEmpty { Text("No LFS files in the current index.").foregroundStyle(.secondary) }
                        DisclosureGroup("LFS Status") { Text(state.status).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                } else { ProgressView() }
                if !store.lfsProgress.isEmpty { Text(store.lfsProgress).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                if let error = store.lfsError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if !store.lfsTransfers.isEmpty { DisclosureGroup("Transfer History") { ForEach(store.lfsTransfers.prefix(30)) { report in VStack(alignment: .leading) { Text(report.operation + " · " + report.remote + " · " + report.date.formatted()).font(.caption.bold()); Text(report.succeeded ? "Completed" : "Failed").foregroundStyle(report.succeeded ? Color.secondary : .orange); Text(report.output).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5) } } }
                if !store.lfsChanges.isEmpty { DisclosureGroup("Settings / Pattern Recovery") { ForEach(store.lfsChanges) { record in HStack { VStack(alignment: .leading) { Text(record.title); Text(record.date.formatted() + " · " + record.state).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Review Restore…") { store.manageLFS(.restore(record)) }.disabled(record.state == "restored" || store.isBusy) }.padding(.vertical, 4) } } }
            }.padding(22).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.task(id: store.lastUpdated) { await store.loadLFS() }
    }
}
struct LFSFileContextMenu: View {
    let store: RepositoryStore
    let path: String
    var body: some View {
        Menu("LFS") {
            Button("Track This File…") { store.manageLFS(.change(.track(path, filename: true, source: ".gitattributes"))) }
            if let ext = path.split(separator: ".").last, path.contains("."), !ext.contains("/") { Button("Track *." + ext + "…") { store.manageLFS(.change(.track("*." + ext, filename: false, source: ".gitattributes"))) } }
            Button("Stage LFS Conversion…") { store.manageLFS(.renormalize([path])) }
            Button("Manage LFS…", action: store.showLFS)
        }.disabled(store.isBusy)
    }
}
