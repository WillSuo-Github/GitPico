import AppKit
import GitCore
import SwiftUI

struct RepositoryInfrastructureSheet: View {
    @Bindable var store: RepositoryStore
    let request: RepositoryInfrastructureRequest
    @Environment(\.dismiss) private var dismiss
    @State private var mode = RepositoryInfrastructureMode.move
    @State private var rootPath = ""
    @State private var destination = ""
    @State private var previousPath = ""
    @State private var replaceBroken = false
    @State private var locations: [String: String] = [:]
    @State private var targets: [PointerRepairTarget] = []
    @State private var migration: MainRepositoryMigrationPlan?
    @State private var repair: PointerRepairPlan?
    @State private var savedRecovery: MainRepositoryRecoveryPlan?
    @State private var selectedMigration: MainRepositoryMigrationBackup?
    @State private var journalPath = ""
    @State private var restore: MainMigrationRestorePlan?
    @State private var selectedRepair: PointerRepairBackup?
    @State private var undoRepair = false
    @State private var migrations: [MainRepositoryMigrationBackup] = []
    @State private var repairs: [PointerRepairBackup] = []
    @State private var loading = false
    @State private var failure: String?
    var reviewed: Bool { migration != nil || repair != nil || restore != nil || selectedRepair != nil || savedRecovery != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            SheetTitle(mode.rawValue, icon: "externaldrive.badge.wifi")
            if !reviewed {
                Picker("Manage", selection: $mode) { ForEach(RepositoryInfrastructureMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                HStack { TextField("Main repository folder containing .git", text: $rootPath).textFieldStyle(.roundedBorder); Button("Choose…") { chooseFolder() } }
                switch mode {
                case .move:
                    HStack { TextField("New absolute destination folder", text: $destination).textFieldStyle(.roundedBorder); Button("Choose…") { chooseDestination() } }
                    Text("Moves working files and shared Git storage together, preserving staging and local/ignored files. Available linked worktrees and nested modules are reconnected. A complete original copy is retained outside both locations (up to 2 GB / 100,000 entries).").foregroundStyle(.secondary)
                case .repair:
                    TextField("Previous main repository path (optional; inferred when unambiguous)", text: $previousPath).textFieldStyle(.roundedBorder)
                    Toggle("Replace missing or invalid .git markers after review", isOn: $replaceBroken).toggleStyle(.checkbox)
                    Text("Scan first, correct relocated folder paths, then review again. Changed module paths update and stage their parent's gitlink and .gitmodules. Working file contents stay intact; live foreign Git storage is protected.").foregroundStyle(.secondary)
                    if !targets.isEmpty { targetList(editable: true) }
                case .history:
                    HStack { TextField("Migration journal directory (optional, for interrupted moves)", text: $journalPath).textFieldStyle(.roundedBorder); Button("Load Journal") { Task { await history() } } }
                    if let selectedMigration {
                        relatedField("Recover saved repository", selectedMigration.source)
                        HStack { TextField("New absolute recovery folder", text: $destination).textFieldStyle(.roundedBorder); Button("Review New-Folder Recovery…") { Task { await reviewSavedRecovery(selectedMigration) } } }
                    }
                    List {
                        Section("Main Repository Migrations") {
                            ForEach(migrations) { record in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text(record.date.formatted()).fontWeight(.medium); Spacer(); Text(record.state).foregroundStyle(.secondary) }
                                    Text(record.source + " → " + record.destination).font(.caption).lineLimit(2).textSelection(.enabled)
                                    if let diagnostic = record.diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.orange) }
                                    HStack {
                                        Button(record.state == "restoring" ? "Review Resume Restore…" : "Review Restore…") { Task { await reviewRestore(record) } }.disabled(!["applied", "restoring"].contains(record.state))
                                        Button("Recover Saved Copy…") { selectedMigration = record }
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                        Section("Pointer Repairs") {
                            ForEach(repairs) { record in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text(record.date.formatted()); Spacer(); Text(record.state).foregroundStyle(.secondary) }
                                    Text("\(record.targets.count) repository locations").font(.caption).foregroundStyle(.secondary)
                                    HStack {
                                        Button("Review Metadata Restore…") { selectedRepair = record; undoRepair = true }.disabled(record.state == "restored")
                                        Button("Review Resume…") { selectedRepair = record; undoRepair = false }.disabled(record.state == "applied" || record.state == "restored")
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                    }.frame(height: 340)
                }
            } else {
                if let migration {
                    relatedField("From", migration.source.path); relatedField("To", migration.destination.path)
                    List(migration.worktrees) { entry in HStack { Text(entry.path).lineLimit(1).truncationMode(.middle); Spacer(); Text(entry.prunable == nil ? "Reconnect" : "Keep missing registration").font(.caption).foregroundStyle(.secondary) } }.frame(height: 230)
                }
                if repair != nil { targetList(editable: false) }
                if let savedRecovery {
                    relatedField("Saved main repository", savedRecovery.backup.source)
                    relatedField("Recover into", savedRecovery.destination.path)
                    Text("Creates an independent copy with the original files, index and Git data. External worktree registrations are removed from this copy; their data stays in the migration backup. Current repositories are kept intact and no network operation runs.").foregroundStyle(.secondary)
                }
                if let restore {
                    relatedField("Current main repository", restore.backup.destination)
                    relatedField("Restore original location", restore.backup.source)
                    relatedField("Recovery copy", restore.backup.journalDirectory)
                    Text("Restores the saved repository and related pointers only while current data matches the recorded state. The migrated repository is retained in quarantine. New files, staging, configuration or pointer changes block this restore.").foregroundStyle(.secondary)
                }
                if let selectedRepair {
                    Text(undoRepair ? "Restore the original pointer metadata" : "Resume known repair steps").font(.headline)
                    List(selectedRepair.targets) { target in VStack(alignment: .leading) { Text(target.title); Text(target.workingPath).font(.caption).foregroundStyle(.secondary) } }.frame(height: 260)
                    Text("Restoring pointer metadata may return a relocated repository to its earlier disconnected state. Saved before/after checks protect newer changes. No working files or commits are removed.").foregroundStyle(.secondary)
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if loading { ProgressView().controlSize(.small) }; Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if reviewed {
                    Button("Back") { migration = nil; repair = nil; restore = nil; selectedRepair = nil; savedRecovery = nil }
                    Button(savedRecovery != nil ? "Recover Saved Copy" : migration != nil ? "Move Repository" : repair != nil ? "Repair Pointers" : restore != nil ? "Restore Migration" : undoRepair ? "Restore Metadata" : "Resume Repair", action: apply).keyboardShortcut(.defaultAction)
                } else if mode == .history { Button("Reload") { Task { await history() } } }
                else {
                    if mode == .repair { Button("Scan Locations") { Task { await preview(scanOnly: true) } } }
                    Button(mode == .move ? "Review Migration…" : "Review Repair…") { Task { await preview() } }.keyboardShortcut(.defaultAction)
                }
            }.disabled(loading || store.isBusy)
        }.padding(24).frame(width: 830).task {
            mode = request.mode
            if let repository = store.repository, let common = try? await repository.commonDirectory(), common.lastPathComponent == ".git" { rootPath = common.deletingLastPathComponent().path }
            else { rootPath = store.snapshot?.root.path ?? "" }
            if mode == .history { await history() }
        }.onChange(of: mode) { migration = nil; repair = nil; restore = nil; selectedRepair = nil; savedRecovery = nil; failure = nil }
    }
    func targetList(editable: Bool) -> some View {
        List(targets) { target in
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(target.title).fontWeight(.medium); Spacer(); if target.missing { Text("Missing / not initialized").font(.caption).foregroundStyle(.orange) }; if target.mappingChanged { Text("Stage path mapping").font(.caption).foregroundStyle(.secondary) } }
                if editable && target.id != "main" { TextField("Current working directory", text: Binding(get: { locations[target.id] ?? target.workingPath }, set: { locations[target.id] = $0 })).textFieldStyle(.roundedBorder) }
                else { Text(target.workingPath).font(.caption).textSelection(.enabled) }
                Text(target.gitDirectory).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.padding(.vertical, 3)
        }.frame(height: 290)
    }
    func rawRepository() throws -> GitRepository {
        guard request.repositoryToken == store.repositoryToken, rootPath.hasPrefix("/") else { throw GitFailure("Choose an absolute main repository path in the current session.") }
        return GitRepository(root: URL(fileURLWithPath: rootPath).resolvingSymlinksInPath())
    }
    func preview(scanOnly: Bool = false) async {
        loading = true; failure = nil; defer { loading = false }
        do {
            let repository = try rawRepository()
            if mode == .move {
                guard destination.hasPrefix("/") else { throw GitFailure("Choose an absolute new destination.") }
                migration = try await repository.previewMainRepositoryMigration(to: URL(fileURLWithPath: destination))
            } else {
                let plan = try await repository.previewPointerRepair(previousMainPath: previousPath.isEmpty ? nil : previousPath, locations: locations, replaceBrokenMarkers: replaceBroken)
                targets = plan.targets; if !scanOnly { repair = plan }
            }
        } catch { failure = error.localizedDescription }
    }
    func history() async {
        loading = true; failure = nil; defer { loading = false }
        do { let repository = try rawRepository(); migrations = try await repository.mainRepositoryMigrations(); if !journalPath.isEmpty { migrations = [try await repository.loadMainMigrationJournal(at: URL(fileURLWithPath: journalPath))] }; repairs = try await repository.pointerRepairBackups() }
        catch { failure = error.localizedDescription }
    }
    func reviewRestore(_ record: MainRepositoryMigrationBackup) async {
        loading = true; failure = nil; defer { loading = false }
        do { restore = try await rawRepository().previewMainMigrationRestore(record) } catch { failure = error.localizedDescription }
    }
    func reviewSavedRecovery(_ record: MainRepositoryMigrationBackup) async {
        loading = true; failure = nil; defer { loading = false }
        do {
            guard destination.hasPrefix("/") else { throw GitFailure("Choose an absolute new recovery destination.") }
            savedRecovery = try await GitRepository(root: URL(fileURLWithPath: record.destination)).previewSavedMainRepositoryRecovery(record, to: URL(fileURLWithPath: destination))
        } catch { failure = error.localizedDescription }
    }
    func apply() {
        guard request.repositoryToken == store.repositoryToken else { failure = "The repository changed. Reopen this preview."; return }
        if let savedRecovery { store.recoverSavedMain(savedRecovery, request: request) }
        else if let migration { store.migrateMain(migration, request: request) }
        else if let repair { store.repairPointers(repair, request: request) }
        else if let restore { store.restoreMainMigration(restore, request: request) }
        else if let selectedRepair { store.resumePointerRepair(selectedRepair, undo: undoRepair, request: request) }
        dismiss()
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.begin { if $0 == .OK, let url = panel.url { rootPath = url.path } }
    }
    func chooseDestination() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Repository"
        panel.begin { if $0 == .OK, let url = panel.url { destination = url.path } }
    }
}
