import GitCore
import SwiftUI

struct LocalChangesSheet: View {
    @Bindable var store: RepositoryStore
    let request: LocalChangeRequest
    @Environment(\.dismiss) private var dismiss
    @State private var scope = DiscardScope.unstaged
    @State private var destination = PatchDestination.workingCopy
    @State private var reverse = false
    @State private var plan: LocalChangePlan?
    @State private var patch: Data?
    @State private var backups: [LocalChangeBackup] = []
    @State private var selectedBackup: UUID?
    @State private var loading = true
    @State private var failure: String?
    @State private var preparationID = UUID()

    var isRecovery: Bool { if case .recovery = request.action { true } else { false } }
    var isExport: Bool {
        switch request.action { case .export, .exportLines: true; default: false }
    }
    var title: String {
        switch request.action {
        case .discard: "Discard Local Changes"
        case .forceAdd: "Force Add Ignored Files"
        case .chunk: "Discard Chunk"
        case .lines: "Discard Selected Lines"
        case .importPatch: "Apply Patch"
        case .export, .exportLines: "Save Patch as File"
        case .recovery: "Recover Local Changes"
        }
    }
    var selected: LocalChangeBackup? { backups.first { $0.id == selectedBackup } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: isRecovery ? "clock.arrow.circlepath" : isExport ? "doc.badge.arrow.up" : "doc.badge.gearshape").foregroundStyle(.secondary)
                SheetTitle(title)
                Spacer()
            }
            switch request.action {
            case .discard:
                Picker("Discard", selection: $scope) { ForEach(DiscardScope.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Text(scope == .unstaged ? "Restore the selected files to their staged contents. Staged changes stay in the index." : "Restore the selected files and their index entries to HEAD. New files will be removed.").font(.callout).foregroundStyle(.secondary)
            case .importPatch(_, let name):
                Text(name).font(.callout).foregroundStyle(.secondary)
                Picker("Apply to", selection: $destination) { ForEach(PatchDestination.allCases, id: \.self) { Text($0.title).tag($0) } }
                Toggle("Reverse patch", isOn: $reverse).toggleStyle(.checkbox)
                Text("Applies file changes without creating commits. Mailbox author and message metadata are not imported.").font(.caption).foregroundStyle(.secondary)
            case .forceAdd:
                Text("These files match ignore rules. Force Add puts them into the index; review their paths before continuing.").font(.callout).foregroundStyle(.secondary)
            case .chunk, .lines:
                Text("Only the selected unstaged changes will be discarded. Staged contents stay in the index.").font(.callout).foregroundStyle(.secondary)
            case .export, .exportLines:
                Text("Includes file contents and binary changes. Review the patch before sharing it.").font(.callout).foregroundStyle(.secondary)
            case .recovery:
                Text("Backups survive app restarts. Restore is blocked if affected files, staging or HEAD changed afterwards.").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            if loading { ProgressView("Preparing preview…").frame(maxWidth: .infinity, minHeight: 230) }
            else if isRecovery {
                HStack(spacing: 0) {
                    List(backups, selection: $selectedBackup) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title).font(.callout.bold())
                            Text(record.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                            Text("\(record.paths.count) files · \(record.state.capitalized)").font(.caption2).foregroundStyle(.secondary)
                        }.tag(record.id)
                    }.frame(width: 265)
                    Divider()
                    ScrollView { Text(selected?.paths.joined(separator: "\n") ?? "Select a backup to inspect its files.").font(.system(.callout, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(12).textSelection(.enabled) }
                }.frame(height: 280).overlay { if backups.isEmpty { ContentUnavailableView("No local change backups", systemImage: "clock.arrow.circlepath") } }
            } else {
                if let plan { Text("\(plan.paths.count) affected files").font(.caption.bold()); Text(plan.paths.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                ScrollView([.horizontal, .vertical]) {
                    Text(plan?.preview ?? patch.map { String(decoding: $0.prefix(256 * 1024), as: UTF8.self) } ?? "")
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(height: 260).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                if let patch, patch.count > 256 * 1024 { Text("Preview limited to 256 KB. The exported file includes the complete patch.").font(.caption).foregroundStyle(.secondary) }
                if !isExport { Label("A local recovery backup is saved before applying this operation.", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary) }
            }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                if !loading { Button("Refresh Preview") { Task { await prepare() } }.disabled(store.isBusy) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isRecovery ? "Restore Changes" : isExport ? "Save Patch…" : title) { submit() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(loading || failure != nil || store.isBusy || (isRecovery ? selected == nil || selected?.state == "restored" : isExport ? patch == nil : plan == nil))
            }
        }.padding(22).frame(width: 740)
            .task(id: scope.rawValue + destination.rawValue + String(reverse)) { await prepare() }
    }
    func prepare() async {
        guard let repository = store.repository, store.repositoryToken == request.repositoryToken else { failure = "The repository changed. Reopen this dialog."; loading = false; return }
        let generation = UUID(); preparationID = generation
        let chosenScope = scope, chosenDestination = destination, chosenReverse = reverse
        loading = true; failure = nil; plan = nil; patch = nil
        var preparedPlan: LocalChangePlan?
        var preparedPatch: Data?
        var preparedBackups: [LocalChangeBackup]?
        do {
            switch request.action {
            case .forceAdd(let paths): preparedPlan = try await repository.previewForceAddIgnored(paths)
            case .discard(let paths): preparedPlan = try await repository.previewDiscard(paths: paths, scope: chosenScope)
            case .chunk(let file, let diff, let id, let context): preparedPlan = try await repository.previewDiscardChunk(file, renderedDiff: diff, hunkID: id, context: context)
            case .lines(let file, let diff, let lines, let context): preparedPlan = try await repository.previewDiscardLines(file, renderedDiff: diff, selection: lines, context: context)
            case .importPatch(let data, _): preparedPlan = try await repository.previewPatch(data, destination: chosenDestination, reverse: chosenReverse)
            case .export(let source, let paths): preparedPatch = try await repository.exportPatch(source, paths: paths)
            case .exportLines(let file, let diff, let lines, let staged, let context): preparedPatch = try await repository.exportSelectedLines(file, renderedDiff: diff, selection: lines, staged: staged, context: context)
            case .recovery:
                preparedBackups = try await repository.localChangeBackups()
            }
            try Task.checkCancellation()
            guard preparationID == generation else { return }
            guard store.repositoryToken == request.repositoryToken else { throw GitFailure("The repository changed. Reopen this dialog.") }
            plan = preparedPlan; patch = preparedPatch
            if let preparedBackups {
                backups = preparedBackups
                if !backups.contains(where: { $0.id == selectedBackup }) { selectedBackup = backups.first(where: { $0.state != "restored" })?.id ?? backups.first?.id }
            }
        } catch is CancellationError { return }
        catch { if preparationID == generation { failure = error.localizedDescription } }
        if preparationID == generation { loading = false }
    }
    func submit() {
        guard !loading, failure == nil, !store.isBusy, store.repositoryToken == request.repositoryToken else { return }
        if isRecovery, let selected { store.restoreLocalBackup(selected.id, request: request) }
        else if let patch { store.savePatch(patch) }
        else if let plan { store.applyLocalPlan(plan, request: request) }
        dismiss()
    }
}
