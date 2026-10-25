import Foundation
import GitCore

enum ManagementAction: Sendable {
    case createBranch(String, String?), renameBranch(Reference), deleteBranch(Reference), upstream(Reference)
    case createTag(String), renameTag(Reference), deleteTag(Reference), inspectTag(Reference)
    case addRemote, editRemote(RemoteConfiguration), renameRemote(RemoteConfiguration), removeRemote(RemoteConfiguration)
    case publish(Reference?, String?, String?, Bool), fetch(RemoteConfiguration?), recovery
}
struct ManagementRequest: Identifiable { let id = UUID(); let action: ManagementAction }

enum StashAction: Sendable {
    case save([String], Bool), apply(Stash), rename(Stash), delete(Stash), clear([Stash]), branch(Stash)
    case files(Stash, [String]), chunk(Stash, StashFile, String, Int), lines(Stash, StashFile, String, Set<PatchLineID>)
}
struct StashRequest: Identifiable { let id = UUID(); let action: StashAction }

extension RepositoryStore {
    func manage(_ action: ManagementAction) { guard !isBusy else { return }; withFreshMetadata([.remotes, .organization]) { self.managementRequest = ManagementRequest(action: action) } }
    func stashAction(_ action: StashAction) { guard !isBusy else { return }; withFreshMetadata([.stashes]) { self.stashRequest = StashRequest(action: action) } }
    func saveStash(_ options: StashSaveOptions) {
        perform(options.snapshot ? "Creating snapshot…" : "Saving stash…", refresh: .workingTree) { _ = try await $0.saveStash(options) }
    }
    func executeStashAction(_ action: StashAction, restoreIndex: Bool = false, deleteAfter: Bool = false, name: String = "") {
        perform("Updating stash…", refresh: .workingTree) { repo in
            switch action {
            case .apply(let stash): try await repo.applyStash(stash, restoreIndex: restoreIndex, deleteAfter: deleteAfter)
            case .rename(let stash): _ = try await repo.renameStash(stash, message: name)
            case .delete(let stash): try await repo.deleteStash(stash)
            case .clear(let expected): try await repo.deleteAllStashes(expected: expected)
            case .branch(let stash): try await repo.branchFromStash(stash, name: name)
            case .files(let stash, let paths): try await repo.applyStashFiles(stash, paths: paths)
            case .chunk(let stash, let file, let diff, let id): try await repo.applyStashHunk(stash, file: file, renderedDiff: diff, hunkID: id)
            case .lines(let stash, let file, let diff, let selection): try await repo.applyStashLines(stash, file: file, renderedDiff: diff, selection: selection)
            case .save: break
            }
        }
    }
    func organize(_ ref: Reference, archived: Bool? = nil, pinned: Bool? = nil) {
        perform("Updating branch organization…") { try await $0.setReferenceOrganization(ref, archived: archived, pinned: pinned) }
    }
    func remoteFor(_ ref: Reference) -> RemoteConfiguration? {
        managedRemotes.sorted { $0.name.count > $1.name.count }.first { ref.name.hasPrefix($0.name + "/") }
    }
}
