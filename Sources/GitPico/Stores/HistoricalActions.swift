import AppKit
import Foundation
import GitCore
import UniformTypeIdentifiers

enum HistoricalAction: Sendable {
    case restore(String?), export, archive
}
struct HistoricalRequest: Identifiable {
    let id = UUID()
    let repositoryToken: UUID
    let revision: String
    let paths: [String]
    let action: HistoricalAction
}

extension RepositoryStore {
    func historical(_ action: HistoricalAction, revision: String, paths: [String] = []) {
        guard !isBusy, repository != nil else { return }
        historicalRequest = HistoricalRequest(repositoryToken: repositoryToken, revision: revision, paths: paths, action: action)
    }
    func applyHistoricalPlan(_ plan: LocalChangePlan, request: HistoricalRequest) {
        guard request.repositoryToken == repositoryToken else { error = String(localized: "The repository changed. Reopen the restore preview."); return }
        perform("Restoring historical files…") { _ = try await $0.applyLocalChange(plan) }
    }
    func saveHistorical(_ snapshot: HistoricalSnapshot, archive: Bool, folder: Bool, name: String) {
        guard !isBusy else { return }
        if folder {
            let panel = NSOpenPanel()
            panel.title = String(localized: "Export Files"); panel.prompt = String(localized: "Export New Folder")
            panel.message = String(localized: "Creates a new folder named \(name). Existing items are kept intact.")
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.begin { [weak self] result in
                guard result == .OK, let parent = panel.url else { return }
                Task { @MainActor in self?.writeHistorical(snapshot, to: parent.appendingPathComponent(name), archive: false, folder: true) }
            }
        } else {
            let panel = NSSavePanel()
            panel.title = archive ? String(localized: "Archive Files at Revision") : String(localized: "Export File at Revision")
            panel.message = String(localized: "Choose a new filename. Existing items are kept intact.")
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = archive ? [.zip] : [.data]
            panel.allowsOtherFileTypes = !archive
            panel.begin { [weak self] result in
                guard result == .OK, let url = panel.url else { return }
                Task { @MainActor in self?.writeHistorical(snapshot, to: url, archive: archive, folder: false) }
            }
        }
    }
    func writeHistorical(_ snapshot: HistoricalSnapshot, to url: URL, archive: Bool, folder: Bool) {
        guard !isBusy else { return }
        isBusy = true; activity = String(localized: "Exporting historical files…")
        Task {
            defer { isBusy = false; activity = "" }
            do {
                try await Task.detached(priority: .userInitiated) {
                    if archive { try HistoricalExport.writeZIP(snapshot, to: url) }
                    else if folder { try HistoricalExport.writeFolder(snapshot, to: url) }
                    else if let file = snapshot.files.first, snapshot.files.count == 1 { try HistoricalExport.writeFile(file, to: url) }
                    else { throw appFailure("Choose one file for raw export.") }
                }.value
            } catch { self.error = error.localizedDescription }
        }
    }
}
