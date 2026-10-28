import Foundation

public struct ManagedWorktree: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let head: String?
    public let branch: String?
    public let isBare: Bool
    public let isMain: Bool
    public let locked: String?
    public let prunable: String?
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
public enum WorktreeBranchMode: String, CaseIterable, Sendable { case existing, new, detached }
public struct WorktreeCreationPlan: Sendable {
    public let destination: URL
    public let hash: String
    public let mode: WorktreeBranchMode
    public let branch: String
    let repository: String
    let common: String
    let reference: Reference?
    public let reuseEmptyDirectory: Bool
}

extension GitRepository {
    nonisolated func gitPathOutput(_ output: GitOutput) throws -> String {
        guard var value = String(data: output.data, encoding: .utf8), value.last == "\n" else { throw GitFailure("Git returned an invalid path.") }
        value.removeLast(); guard !value.isEmpty, !value.utf8.contains(0) else { throw GitFailure("Git returned an empty path.") }; return value
    }
    public func commonDirectory() async throws -> URL {
        URL(fileURLWithPath: try gitPathOutput(await GitProcess.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root))).resolvingSymlinksInPath()
    }
    // Resolve the existing parent too: Foundation leaves symlink aliases intact for missing leaves.
    nonisolated func worktreePath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) { return url.resolvingSymlinksInPath().path }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return url.path }
        return URL(fileURLWithPath: worktreePath(parent.path)).appendingPathComponent(url.lastPathComponent).path
    }
    public func managedWorktrees() async throws -> [ManagedWorktree] {
        let output = try await GitProcess.run(["worktree", "list", "--porcelain", "-z"], at: root)
        guard let value = String(data: output.data, encoding: .utf8) else { throw GitFailure("Worktree paths must use UTF-8.") }
        var records: [ManagedWorktree] = [], path: String?, head: String?, branch: String?, bare = false, locked: String?, prunable: String?
        func append() {
            if let path { records.append(ManagedWorktree(path: path, head: head, branch: branch, isBare: bare, isMain: records.isEmpty, locked: locked, prunable: prunable)) }
        }
        for field in value.components(separatedBy: "\0") {
            if field.hasPrefix("worktree ") { append(); try checkManagementAncestors(URL(fileURLWithPath: String(field.dropFirst(9)))); path = worktreePath(String(field.dropFirst(9))); head = nil; branch = nil; bare = false; locked = nil; prunable = nil }
            else if field.hasPrefix("HEAD ") { head = String(field.dropFirst(5)) }
            else if field.hasPrefix("branch ") { branch = String(field.dropFirst(7)) }
            else if field == "bare" { bare = true }
            else if field == "locked" { locked = "" }
            else if field.hasPrefix("locked ") { locked = String(field.dropFirst(7)) }
            else if field == "prunable" { prunable = "" }
            else if field.hasPrefix("prunable ") { prunable = String(field.dropFirst(9)) }
        }
        append(); return records
    }
    func requireWorktree(_ expected: ManagedWorktree) async throws {
        guard try await managedWorktrees().first(where: { $0.path == expected.path }) == expected else { throw GitFailure("The worktree changed. Refresh its preview.") }
    }
    func newWorktreeDestination(_ url: URL) async throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw GitFailure("Choose an absolute local destination.") }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath(), destination = parent.appendingPathComponent(url.lastPathComponent)
        guard try localAttributes(destination) == nil, let attributes = try localAttributes(parent), attributes[.type] as? FileAttributeType == .typeDirectory else { throw GitFailure("Choose a new destination inside an existing parent directory.") }
        let common = try await commonDirectory()
        for base in try await managedWorktrees().map({ URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() }) + [common] {
            guard destination.path != base.path, !destination.path.hasPrefix(base.path + "/"), !base.path.hasPrefix(destination.path + "/") else { throw GitFailure("Choose a destination outside all existing worktrees and Git storage.") }
        }
        return destination
    }
    func worktreeCreationDestination(_ url: URL, reuseEmpty: Bool) async throws -> URL {
        if !reuseEmpty { return try await newWorktreeDestination(url) }
        let destination = URL(fileURLWithPath: worktreePath(url.path))
        guard url.isFileURL, url.path.hasPrefix("/"), try localAttributes(destination)?[.type] as? FileAttributeType == .typeDirectory, try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty else { throw GitFailure("Choose an existing empty local directory for reuse.") }
        try checkManagementAncestors(url)
        for tree in try await managedWorktrees() {
            guard destination.path != tree.path, !destination.path.hasPrefix(tree.path + "/"), !tree.path.hasPrefix(destination.path + "/") else { throw GitFailure("The reused directory overlaps an existing worktree.") }
        }
        let common = try await commonDirectory().path
        guard !destination.path.hasPrefix(common + "/"), destination.path != common else { throw GitFailure("The reused directory overlaps Git storage.") }
        return destination
    }
    public func previewWorktreeCreation(destination: URL, mode: WorktreeBranchMode, branch: String = "", revision: String = "HEAD", reuseEmptyDirectory: Bool = false) async throws -> WorktreeCreationPlan {
        let destination = try await worktreeCreationDestination(destination, reuseEmpty: reuseEmptyDirectory)
        let hash: String, reference: Reference?
        switch mode {
        case .existing:
            guard let ref = try await references().first(where: { $0.isLocal && ($0.name == branch || $0.fullName == branch) }) else { throw GitFailure("Choose an existing local branch.") }
            guard !(try await managedWorktrees().contains { $0.branch == ref.fullName }) else { throw GitFailure("This branch is already checked out in another worktree.") }
            hash = ref.hash; reference = ref
        case .new:
            try await validateReferenceName(branch)
            guard !(try await references().contains { $0.fullName == "refs/heads/" + branch }) else { throw GitFailure("The new branch name already exists.") }
            hash = try await verifiedCommit(revision); reference = nil
        case .detached: hash = try await verifiedCommit(revision); reference = nil
        }
        return WorktreeCreationPlan(destination: destination, hash: hash, mode: mode, branch: reference?.name ?? branch, repository: root.path, common: try await commonDirectory().path, reference: reference, reuseEmptyDirectory: reuseEmptyDirectory)
    }
    @discardableResult public func createWorktree(_ plan: WorktreeCreationPlan) async throws -> ManagedWorktree {
        guard plan.repository == root.path, try await commonDirectory().path == plan.common else { throw GitFailure("The repository changed. Reopen the worktree preview.") }
        _ = try await worktreeCreationDestination(plan.destination, reuseEmpty: plan.reuseEmptyDirectory)
        if let reference = plan.reference { try await requireReference(reference) }
        let options: [String]
        switch plan.mode {
        case .existing: options = []
        case .new: try await validateReferenceName(plan.branch); options = ["--no-track", "-b", plan.branch]
        case .detached: options = ["--detach"]
        }
        _ = try await GitProcess.run(["worktree", "add"] + options + ["--", plan.destination.path, plan.mode == .existing ? plan.branch : plan.hash], at: root, timeout: 120)
        guard let record = try await managedWorktrees().first(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == plan.destination.resolvingSymlinksInPath().path }), record.head == plan.hash else { throw GitFailure("Git created a worktree but its state differs from the preview. Inspect the worktree list before continuing.") }
        return record
    }
    public func checkedWorktree(_ record: ManagedWorktree) async throws -> GitRepository {
        try await requireWorktree(record)
        guard !record.isBare, record.prunable == nil else { throw GitFailure("Repair the missing worktree before opening it.") }
        let url = URL(fileURLWithPath: record.path)
        guard let attrs = try localAttributes(url), attrs[.type] as? FileAttributeType == .typeDirectory else { throw GitFailure("The worktree folder is missing or has become a symbolic link.") }
        let repository = try await GitRepository.open(url)
        guard repository.root.path == url.resolvingSymlinksInPath().path, try await repository.commonDirectory().path == commonDirectory().path else { throw GitFailure("This folder is no longer a worktree of the current repository.") }
        return repository
    }
    func requireCleanTreeForManagement(_ repository: GitRepository) async throws {
        guard try await repository.currentOperation() == .none else { throw GitFailure("Finish the operation in this working tree first.") }
        let directory = repository.root
        guard try await GitProcess.run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching", "--ignore-submodules=none"], at: directory).data.isEmpty else { throw GitFailure("Commit or move aside every local, untracked and ignored file before changing this working tree.") }
    }
    public func setWorktreeLocked(_ record: ManagedWorktree, locked: Bool, reason: String = "") async throws {
        try await requireWorktree(record)
        guard !record.isMain, !reason.utf8.contains(0) else { throw GitFailure("Only a linked worktree can be locked.") }
        let arguments = locked ? ["worktree", "lock"] + (reason.isEmpty ? [] : ["--reason", reason]) : ["worktree", "unlock"]
        _ = try await GitProcess.run(arguments + ["--", record.path], at: root)
    }
    public func moveWorktree(_ record: ManagedWorktree, to destination: URL) async throws {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        try await requireWorktree(record)
        guard !record.isMain, record.locked == nil, record.path != root.path else { throw GitFailure("Open another working tree and unlock this linked worktree before moving it.") }
        let child = try await checkedWorktree(record); try await requireCleanTreeForManagement(child)
        for module in try await child.managedSubmodules() { try await child.requireModuleTreeClean(module, recursive: true) }
        let destination = try await newWorktreeDestination(destination)
        let pointers = try await child.repositoryPointers(includeRoot: false, allowedStorage: commonDirectory())
        let admin = try await worktreeAdministration(record)
        var backup = try await beginRelatedBackup(title: localized("Move Worktree") + " · " + record.name, kind: "worktree", original: record.path, current: destination.path, pointers: pointers, extraFiles: [admin.appendingPathComponent("gitdir").path])
        backup.worktree = record; try await saveRelatedBackup(backup)
        try await requireWorktree(record)
        do {
            try FileManager.default.moveItem(at: URL(fileURLWithPath: record.path), to: destination)
            _ = try await GitProcess.run(["worktree", "repair", "--", destination.path], at: root)
            try await reconnectPointers(pointers, from: record.path, to: destination.path)
            try await finishRelatedBackup(backup)
        } catch { try? await finishRelatedBackup(backup, error: error); throw error }
    }
    func worktreeAdministration(_ record: ManagedWorktree) async throws -> URL {
        let directory = try await commonDirectory().appendingPathComponent("worktrees")
        for child in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard try localAttributes(child)?[.type] as? FileAttributeType == .typeDirectory else { continue }
            let marker = child.appendingPathComponent("gitdir")
            if let attributes = try localAttributes(marker), attributes[.type] as? FileAttributeType == .typeRegular, let data = try? Data(contentsOf: marker), var path = String(data: data, encoding: .utf8) {
                if path.last == "\n" { path.removeLast() }
                if worktreePath(path) == worktreePath(URL(fileURLWithPath: record.path).appendingPathComponent(".git").path) { return child }
            }
        }
        throw GitFailure("The worktree administrative entry could not be verified.")
    }
    public func repairWorktree(_ record: ManagedWorktree, at location: URL) async throws {
        try await requireWorktree(record)
        guard !record.isMain else { throw GitFailure("Open the relocated main repository to repair its linked worktrees.") }
        let administration = try await worktreeAdministration(record)
        let location = location.standardizedFileURL
        let marker = location.appendingPathComponent(".git")
        guard let attributes = try localAttributes(marker), attributes[.type] as? FileAttributeType == .typeRegular, let data = try? Data(contentsOf: marker), var text = String(data: data, encoding: .utf8), text.hasPrefix("gitdir: ") else { throw GitFailure("Choose the relocated worktree containing its original .git file.") }
        text.removeFirst(8); if text.last == "\n" { text.removeLast() }
        let target = text.hasPrefix("/") ? URL(fileURLWithPath: text) : location.appendingPathComponent(text)
        guard target.resolvingSymlinksInPath().path == administration.resolvingSymlinksInPath().path else { throw GitFailure("This folder belongs to another worktree.") }
        _ = try await GitProcess.run(["worktree", "repair", "--", location.path], at: root)
    }
    public func removeWorktree(_ record: ManagedWorktree, force: Bool = false, unlock: Bool = false, missingOnly: Bool = false) async throws {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        try await requireWorktree(record)
        guard !record.isMain, !record.isBare, (record.locked == nil || (force && unlock)), record.path != root.path else { throw GitFailure("Open a different worktree and unlock the linked worktree before removing it.") }
        if missingOnly, try localAttributes(URL(fileURLWithPath: record.path)) != nil { throw GitFailure("The stale worktree reappeared. Review it before removing any directory.") }
        var pointers: [RepositoryPointer] = []
        if try localAttributes(URL(fileURLWithPath: record.path)) != nil {
            let child = try await checkedWorktree(record)
            if !force {
                try await requireCleanTreeForManagement(child)
                for module in try await child.managedSubmodules() { try await child.requireModuleTreeClean(module, recursive: true, requireRecorded: true) }
            }
            pointers = try await child.repositoryPointers(includeRoot: false, allowedStorage: commonDirectory())
        }
        let admin = try await worktreeAdministration(record)
        if let hash = record.head { try await checkpoint(hash, id: UUID(), side: "removed-worktree") }
        if let index = try readLocalIndex(admin.appendingPathComponent("index")) { try await pinManagementIndex(index, id: UUID(), side: "removed-worktree-index") }
        var backup = try await beginRelatedBackup(title: (force ? localized("Force Remove Worktree") : localized("Remove Worktree")) + " · " + record.name, kind: "worktree", original: record.path, current: record.path, pointers: pointers, extraFiles: [admin.appendingPathComponent("gitdir").path], extraDirectories: [admin.path])
        backup.worktree = record; try await saveRelatedBackup(backup)
        try await requireWorktree(record)
        do {
            if record.locked != nil { _ = try await GitProcess.run(["worktree", "unlock", "--", record.path], at: root) }
            // Retain the original directory before unregistering a missing path. This also
            // handles initialized nested modules without forcing Git to delete their data.
            if try localAttributes(URL(fileURLWithPath: record.path)) != nil {
                let quarantine = try await relatedBackupDirectory(backup.summary.id).appendingPathComponent("removed-original")
                try FileManager.default.moveItem(at: URL(fileURLWithPath: record.path), to: quarantine)
            }
            _ = try await GitProcess.run(["worktree", "remove", "--", record.path], at: root, timeout: 120)
            try await finishRelatedBackup(backup)
        } catch { try? await finishRelatedBackup(backup, error: error); throw error }
    }
}
