import GitCore
import SwiftUI

struct LFSManagementSheet: View {
    let store: RepositoryStore
    let request: LFSRequest
    @Environment(\.dismiss) private var dismiss
    @State private var pattern = ""
    @State private var source = ".gitattributes"
    @State private var filename = false
    @State private var installHook = true
    @State private var remote = "origin"
    @State private var revision = "HEAD"
    @State private var allObjects = false
    @State private var change: LFSChangePlan?
    @State private var transfer: LFSTransferPlan?
    @State private var staging: LFSStagingPlan?
    @State private var reviewedRestore = false
    @State private var loading = false
    @State private var failure: String?
    var reviewed: Bool { change != nil || transfer != nil || staging != nil || reviewedRestore }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Git LFS", systemImage: "externaldrive").font(.title2.bold())
            if let staging {
                Text("Stage LFS Conversion").font(.headline)
                List(staging.paths, id: \.self) { Text($0).font(.caption) }.frame(height: 180)
                Text(staging.summary).font(.caption.monospaced()).textSelection(.enabled)
                Text("Stages the selected files' current working contents with LFS filters. Working bytes and other files' staging are kept. Earlier staging is saved in LFS Settings / Pattern Recovery. Existing history is not rewritten.").foregroundStyle(.secondary)
            } else if let change {
                Text(change.title).font(.headline)
                ForEach(change.paths, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                ScrollView { Text(change.preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 290)
            } else if let transfer {
                Text(transfer.operation.rawValue + " · " + transfer.remote).font(.headline)
                Text(transfer.hash).font(.caption.monospaced()).textSelection(.enabled)
                Text(transfer.endpoint).font(.caption).textSelection(.enabled)
                Text("Transfers immutable LFS objects; Git branches are not pushed or pulled. Pull checks out cached content only after checking HEAD and staging again. Modified working files are kept by Git LFS.").font(.callout).foregroundStyle(.secondary)
                if transfer.allObjects { Text("All history reachable from this revision is included. The list below shows files at the selected revision, not the total transfer count.").font(.caption).foregroundStyle(.orange) }
                List(transfer.paths, id: \.self) { Text($0).font(.caption) }.frame(height: 220)
            } else {
                switch request.action {
                case .renormalize(let paths):
                    Text("Convert existing tracked files to LFS").font(.headline)
                    Text(paths.isEmpty ? "Review up to 128 tracked files that match current LFS attributes." : paths.joined(separator: "\n")).font(.caption)
                    Text("Current file contents will be staged after applying LFS filters. Review the file list before applying.").foregroundStyle(.secondary)
                case .change(let action):
                    switch action {
                    case .enable:
                        Text("Enable repository-local LFS filters").font(.headline)
                        Toggle("Install repository pre-push hook", isOn: $installHook).toggleStyle(.checkbox)
                        Text("Existing custom/external hooks will not be overwritten. Disable this option to enable filters only, then integrate git lfs pre-push into your own hook. Global Git settings stay unchanged.").foregroundStyle(.secondary)
                    case .disable:
                        Text("Disable filters in this repository").font(.headline)
                        Text("Keeps .gitattributes, history, cached objects and hooks. Existing LFS files are not converted back to normal Git storage.").foregroundStyle(.secondary)
                    case .track, .untrack:
                        TextField("Pattern or literal filename", text: $pattern).textFieldStyle(.roundedBorder)
                        TextField("Attributes file", text: $source).textFieldStyle(.roundedBorder)
                        if case .track = action { Toggle("Treat as a literal filename", isOn: $filename).toggleStyle(.checkbox) }
                        Text("Changes only the reviewed .gitattributes. Files and staging are preserved; no historical commits are rewritten. Commit the attributes change and re-stage existing files explicitly when converting them.").foregroundStyle(.secondary)
                    }
                case .transfer(let operation):
                    Text(operation.rawValue).font(.headline)
                    if operation != .checkout {
                        Picker("Remote", selection: $remote) { ForEach(store.managedRemotes) { item in Text(item.name).tag(item.name) } }
                        TextField("Revision", text: $revision).textFieldStyle(.roundedBorder)
                        if operation == .fetch || operation == .push { Toggle("Include all LFS objects in history reachable from this revision", isOn: $allObjects).toggleStyle(.checkbox) }
                    }
                case .restore(let record):
                    Text("Restore · " + record.title).font(.headline)
                    Text(record.date.formatted()).foregroundStyle(.secondary)
                    ForEach(record.affectedPaths, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    Text("Restores saved local configuration or attributes only while HEAD and the recorded files still match. Later changes are preserved. Saved conversion records restore the earlier index; working file contents are preserved.").foregroundStyle(.secondary)
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if loading { ProgressView().controlSize(.small) }; Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if reviewed {
                    Button("Back") { change = nil; transfer = nil; reviewedRestore = false; staging = nil }
                    Button(transfer == nil ? "Apply" : "Run Transfer") { apply() }.keyboardShortcut(.defaultAction)
                } else { Button("Review…") { Task { await review() } }.keyboardShortcut(.defaultAction) }
            }.disabled(loading || store.isBusy)
        }.padding(24).frame(width: 720).task {
            remote = store.managedRemotes.first?.name ?? "origin"
            if case .change(let action) = request.action {
                switch action { case .track(let value, let literal, let file): pattern = value; filename = literal; source = file; case .untrack(let value, let file): pattern = value; source = file; default: break }
            }
        }
    }
    func review() async {
        guard let repository = store.repository, request.token == store.repositoryToken else { failure = "The repository changed. Reopen this LFS preview."; return }
        loading = true; failure = nil; defer { loading = false }
        do {
            switch request.action {
            case .renormalize(let paths): staging = try await repository.previewLFSStaging(paths: paths)
            case .change(let action):
                let submitted: LFSChange
                switch action { case .enable: submitted = .enable(installHook: installHook); case .disable: submitted = .disable; case .track: submitted = .track(pattern, filename: filename, source: source); case .untrack: submitted = .untrack(pattern, source: source) }
                change = try await repository.previewLFSChange(submitted)
            case .transfer(let operation): transfer = try await repository.previewLFSTransfer(operation, remote: remote, revision: revision, allObjects: allObjects)
            case .restore: reviewedRestore = true
            }
        } catch { failure = error.localizedDescription }
    }
    func apply() {
        if let staging { store.stageLFS(staging, request: request) }
        else if let change { store.applyLFS(change, request: request) }
        else if let transfer { store.transferLFS(transfer, request: request) }
        else if case .restore(let record) = request.action { store.restoreLFS(record, request: request) }
        dismiss()
    }
}
