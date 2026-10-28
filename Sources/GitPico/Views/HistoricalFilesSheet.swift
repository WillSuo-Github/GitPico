import GitCore
import SwiftUI

struct HistoricalFilesSheet: View {
    @Bindable var store: RepositoryStore
    let request: HistoricalRequest
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: HistoricalSnapshot?
    @State private var selected: String?
    @State private var destination = ""
    @State private var target = HistoricalRestoreTarget.workingCopy
    @State private var folderName = ""
    @State private var plan: LocalChangePlan?
    @State private var loading = true
    @State private var preparing = false
    @State private var failure: String?
    @State private var generation = UUID()
    var restoring: Bool { if case .restore = request.action { true } else { false } }
    var archive: Bool { if case .archive = request.action { true } else { false } }
    var singleFile: Bool { snapshot?.files.count == 1 && request.paths == [snapshot?.files.first?.path ?? ""] }
    var folder: Bool { !restoring && !archive && !singleFile }
    var title: LocalizedStringResource { restoring ? "Restore Files in Working Copy" : archive ? "Archive Files at Revision" : "Export Files at Revision" }
    var chosen: HistoricalFile? { snapshot?.files.first { $0.path == selected } }
    var validFolderName: Bool { !folderName.isEmpty && folderName != "." && folderName != ".." && !folderName.contains("/") && !folderName.utf8.contains(0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle(title, icon: restoring ? "clock.arrow.circlepath" : archive ? "doc.zipper" : "square.and.arrow.up")
            if let snapshot {
                HStack { Text(snapshot.revision).font(.system(size: 11, design: .monospaced)).textSelection(.enabled); Spacer(); Text("\(snapshot.files.count) entries · \(snapshot.totalBytes.formatted(.byteCount(style: .file)))").font(.caption).foregroundStyle(.secondary) }
                if restoring {
                    Picker("Restore to", selection: $target) { ForEach(HistoricalRestoreTarget.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    if snapshot.files.count == 1 { TextField("Destination path in working copy", text: $destination).textFieldStyle(.roundedBorder) }
                    Text(target == .workingCopy ? "Restores the selected version in your working copy. Staged contents stay unchanged." : "Restores and stages the selected version. Existing local changes are backed up first.").font(.callout).foregroundStyle(.secondary)
                } else if folder { TextField("New export folder name", text: $folderName).textFieldStyle(.roundedBorder) }
                ForEach(snapshot.warnings, id: \.self) { Label($0, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                Divider()
                HStack(spacing: 0) {
                    List(snapshot.files, selection: $selected) { file in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(file.path, systemImage: file.isSubmodule ? "shippingbox" : file.isLink ? "link" : "doc").lineLimit(2).truncationMode(.middle)
                            Text("\(file.mode) · \(file.data.count.formatted(.byteCount(style: .file)))").font(.caption2).foregroundStyle(.secondary)
                        }.font(.callout).tag(file.path)
                    }.frame(width: 280)
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        if let file = chosen {
                            if file.isSubmodule { Text("Submodule: \(file.object)\nExported as an empty directory.").font(.callout).padding(12) }
                            else if !file.data.contains(0), let text = String(data: file.data.prefix(64 * 1024), encoding: .utf8) {
                                Text(text.isEmpty ? String(localized: "Empty file") : text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(12)
                            } else { Text("Binary file · \(file.data.count) bytes\nExports preserve the original bytes.").font(.callout).foregroundStyle(.secondary).padding(12) }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.frame(height: 275)
                if chosen?.data.count ?? 0 > 64 * 1024 { Text("Text preview limited to 64 KB. Export includes complete contents.").font(.caption).foregroundStyle(.secondary) }
                if restoring { Label("A recovery backup is saved before writing. New external edits block restoration.", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary) }
                else { Text("Exports use the exact Git object bytes, without export-ignore, export-subst or LFS downloads. Existing destinations are never replaced.").font(.caption).foregroundStyle(.secondary) }
            }
            if loading || preparing { ProgressView(loading ? "Reading historical files…" : "Preparing restore preview…").controlSize(.small).frame(maxWidth: .infinity, minHeight: loading ? 230 : 18) }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                if restoring && snapshot != nil { Button("Refresh Preview") { Task { await prepareRestore() } }.disabled(preparing) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(restoring ? "Restore Files" : archive ? "Save ZIP…" : folder ? "Choose Parent Folder…" : "Save File…", action: submit)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(loading || preparing || failure != nil || store.isBusy || (restoring && plan == nil) || (folder && !validFolderName))
            }
        }.padding(22).frame(width: 800)
        .task { await load() }
        .task(id: destination + target.rawValue) { if snapshot != nil && restoring { await prepareRestore() } }
    }
    func load() async {
        guard let repository = store.repository, store.repositoryToken == request.repositoryToken else { failure = String(localized: "The repository changed. Reopen this dialog."); loading = false; return }
        do {
            let value = try await repository.historicalSnapshot(revision: request.revision, paths: request.paths)
            try Task.checkCancellation()
            guard store.repositoryToken == request.repositoryToken else { throw appFailure("The repository changed. Reopen this dialog.") }
            if case .restore(let suggested) = request.action { destination = suggested ?? value.files.first?.path ?? "" }
            snapshot = value; selected = value.files.first?.path
            folderName = store.title + "-" + value.revision.prefix(8)
            loading = false
            if restoring { await prepareRestore() }
            else {
                try HistoricalExport.validate(value)
                if singleFile, !archive, value.files.first?.isRegular != true { failure = String(localized: "Raw export requires a regular file. Choose Archive to preserve this entry.") }
            }
        } catch { if !Task.isCancelled { failure = error.localizedDescription; loading = false } }
    }
    func prepareRestore() async {
        guard let repository = store.repository, let snapshot, store.repositoryToken == request.repositoryToken else { return }
        let token = UUID(); generation = token; preparing = true; failure = nil; plan = nil
        let chosenDestination = snapshot.files.count == 1 ? destination : nil, chosenTarget = target
        do {
            let value = try await repository.previewHistoricalRestore(snapshot, destination: chosenDestination, target: chosenTarget)
            try Task.checkCancellation()
            guard generation == token, store.repositoryToken == request.repositoryToken else { return }
            plan = value; preparing = false
        } catch { if generation == token && !Task.isCancelled { failure = error.localizedDescription; preparing = false } }
    }
    func submit() {
        guard !loading, !preparing, failure == nil, !store.isBusy, store.repositoryToken == request.repositoryToken, let snapshot else { return }
        if restoring, let plan { store.applyHistoricalPlan(plan, request: request) }
        else {
            let name = archive ? folderName + ".zip" : folder ? folderName : (snapshot.files.first?.path as NSString?)?.lastPathComponent ?? "file"
            store.saveHistorical(snapshot, archive: archive, folder: folder, name: name)
        }
        dismiss()
    }
}

struct HistoricalFileMenu: View {
    @Bindable var store: RepositoryStore
    let revision: String
    let paths: [String]
    var destination: String? = nil
    var body: some View {
        Button("Restore at Revision in Working Copy…") { store.historical(.restore(destination), revision: revision, paths: paths) }.disabled(store.isBusy)
        Button("Export Original Files…") { store.historical(.export, revision: revision, paths: paths) }.disabled(store.isBusy)
        Button("Archive as ZIP…") { store.historical(.archive, revision: revision, paths: paths) }.disabled(store.isBusy)
    }
}
