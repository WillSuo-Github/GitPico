import AppKit
import Foundation
import GitCore
import UniformTypeIdentifiers

enum LocalChangeAction: Sendable {
    case discard([String])
    case forceAdd([String])
    case chunk(FileChange, String, Int, Int)
    case lines(FileChange, String, Set<PatchLineID>, Int)
    case importPatch(Data, String)
    case export(PatchExportSource, [String])
    case exportLines(FileChange, String, Set<PatchLineID>, Bool, Int)
    case recovery
}
struct LocalChangeRequest: Identifiable {
    let id = UUID()
    let repositoryToken: UUID
    let action: LocalChangeAction
}

extension RepositoryStore {
    func localChange(_ action: LocalChangeAction) {
        guard !isBusy, repository != nil else { return }
        localChangeRequest = LocalChangeRequest(repositoryToken: repositoryToken, action: action)
    }
    func discardSelection(_ path: String? = nil) {
        let paths = path.map { selectedWorkingFiles.contains($0) ? selectedWorkingFiles.sorted() : [$0] } ?? selectedWorkingFiles.sorted()
        if !paths.isEmpty { localChange(.discard(paths)) }
    }
    func applyLocalPlan(_ plan: LocalChangePlan, request: LocalChangeRequest) {
        guard request.repositoryToken == repositoryToken else { error = "The repository changed. Reopen the preview."; return }
        let refresh: MutationRefresh
        if case .forceAdd = request.action { refresh = .index } else { refresh = .full }
        perform(plan.title + "…", refresh: refresh) { _ = try await $0.applyLocalChange(plan) }
    }
    func restoreLocalBackup(_ id: UUID, request: LocalChangeRequest) {
        guard request.repositoryToken == repositoryToken else { error = "The repository changed. Reopen recovery."; return }
        perform("Restoring local changes…") { try await $0.restoreLocalChanges(id) }
    }
    func choosePatch() {
        guard !isBusy, repository != nil else { return }
        let token = repositoryToken
        let panel = NSOpenPanel()
        panel.title = "Apply Patch"; panel.prompt = "Review Patch"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .data, UTType(filenameExtension: "diff") ?? .data, .plainText]
        panel.allowsOtherFileTypes = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, self.repositoryToken == token, !self.isBusy else { return }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size <= 16 * 1024 * 1024 else { throw GitFailure("Choose a patch up to 16 MB.") }
                    self.localChange(.importPatch(try Data(contentsOf: url), url.lastPathComponent))
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    func savePatch(_ data: Data) {
        let panel = NSSavePanel()
        panel.title = "Save Patch as File"; panel.nameFieldStringValue = "changes.patch"
        panel.message = "Choose a new filename. Existing files are kept intact."
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .data]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try writeNewPatchFile(data, to: url) }
            catch { Task { @MainActor in self?.error = error.localizedDescription } }
        }
    }
}

func writeNewPatchFile(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .withoutOverwriting)
}
