import Foundation
import Darwin

public enum SubmoduleDirectoryMode: String, CaseIterable, Sendable {
    case newDirectory = "New Directory", emptyDirectory = "Existing Empty Directory", existingRepository = "Existing Repository", retainedRepository = "Retained Git Repository", archiveAndClone = "Back Up Retained Repository and Clone Fresh"
}
struct SubmoduleDirectoryState: Equatable, Sendable {
    let mode: SubmoduleDirectoryMode
    let workingDigest: String?
    let gitDirectory: String?
    let storageDigest: String?
    let head: HeadPosition?
}
extension GitRepository {
    func retainedModuleDirectory(_ name: String) async throws -> URL {
        try validateModuleName(name)
        let base = try await submoduleStorageDirectory(), directory = base.appendingPathComponent(name)
        try checkManagementAncestors(directory)
        guard directory.path.hasPrefix(base.path + "/") else { throw GitFailure("The retained Git directory is outside module storage.") }
        return directory
    }
    func requireRetainedModuleUnclaimed(_ directory: URL, target: URL? = nil, inspectNested: Bool = true) async throws {
        try await requireSingleRetainedModuleUnclaimed(directory, target: target)
        guard inspectNested else { return }
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { throw GitFailure("Unable to inspect retained Git storage.") }
        var inspected = 0
        while let entry = entries.nextObject() as? URL {
            inspected += 1
            guard inspected <= 100_000 else { throw GitFailure("Retained storage inspection exceeds 100,000 entries.") }
            let attributes = try localAttributes(entry)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink { entries.skipDescendants(); continue }
            if attributes?[.type] as? FileAttributeType == .typeDirectory, ["objects", "refs", "logs", "hooks", "gitpico"].contains(entry.lastPathComponent) { entries.skipDescendants(); continue }
            if entry.lastPathComponent == "config", worktreePath(entry.deletingLastPathComponent().path) != worktreePath(directory.path), try localAttributes(entry.deletingLastPathComponent().appendingPathComponent("objects"))?[.type] as? FileAttributeType == .typeDirectory {
                try await requireSingleRetainedModuleUnclaimed(entry.deletingLastPathComponent(), target: nil, targetRoot: target)
            }
        }
    }
    private func requireSingleRetainedModuleUnclaimed(_ directory: URL, target: URL?, targetRoot: URL? = nil) async throws {
        let registrations = directory.appendingPathComponent("worktrees")
        if let entries = try? FileManager.default.contentsOfDirectory(at: registrations, includingPropertiesForKeys: nil) {
            for entry in entries {
                guard let data = try readLocalIndex(entry.appendingPathComponent("gitdir")), var text = String(data: data, encoding: .utf8) else { continue }
                if text.last == "\n" { text.removeLast() }
                if try localAttributes(URL(fileURLWithPath: text)) != nil { throw GitFailure("A linked working tree still uses this retained repository. Remove or relocate that registration before reuse or cleanup.") }
            }
        }
        if let data = try readLocalIndex(directory.appendingPathComponent("config")) {
            _ = data
            let output = try await GitProcess.run(["config", "--file", directory.appendingPathComponent("config").path, "--get", "core.worktree"], at: root, allowed: [0, 1])
            if output.status == 0 {
                let text = try gitPathOutput(output), owner = text.hasPrefix("/") ? URL(fileURLWithPath: text) : directory.appendingPathComponent(text)
                let ownerPath = owner.resolvingSymlinksInPath().path
                let insideTarget = targetRoot.map { ownerPath.hasPrefix($0.resolvingSymlinksInPath().path + "/") } ?? false
                if try localAttributes(owner) != nil, ownerPath != target?.resolvingSymlinksInPath().path, !insideTarget,
                   let repo = try? await GitRepository.open(owner), repo.root.path == owner.resolvingSymlinksInPath().path {
                    let actual = try await GitProcess.run(["rev-parse", "--absolute-git-dir"], at: repo.root)
                    if worktreePath(try gitPathOutput(actual)) == worktreePath(directory.path) { throw GitFailure("The retained repository is still used by another working directory: " + ownerPath + "\nGit storage: " + directory.path + "\nReviewed destination: " + (target?.path ?? targetRoot?.path ?? "none")) }
                }
            }
        }
    }
    func inspectSubmoduleDirectory(path: String, name: String, mode: SubmoduleDirectoryMode) async throws -> SubmoduleDirectoryState {
        let working = try validateLocalPath(path), retained = try await retainedModuleDirectory(name)
        let attributes = try localAttributes(working)
        var admin: URL?, head: HeadPosition?
        switch mode {
        case .newDirectory:
            guard attributes == nil, try localAttributes(retained) == nil else { throw GitFailure("The destination or retained Git directory exists. Choose an explicit reuse mode.") }
        case .emptyDirectory:
            guard attributes?[.type] as? FileAttributeType == .typeDirectory, try FileManager.default.contentsOfDirectory(atPath: working.path).isEmpty, try localAttributes(retained) == nil else { throw GitFailure("Choose an empty directory without retained Git storage, or select the retained-repository mode.") }
        case .existingRepository:
            let child = try await GitRepository.open(working)
            guard child.root.path == working.resolvingSymlinksInPath().path else { throw GitFailure("Select the root of an existing nested repository.") }
            let directory = URL(fileURLWithPath: try gitPathOutput(await GitProcess.run(["rev-parse", "--absolute-git-dir"], at: working))).resolvingSymlinksInPath()
            guard directory.path == working.appendingPathComponent(".git").resolvingSymlinksInPath().path || directory.path == retained.resolvingSymlinksInPath().path else { throw GitFailure("The existing repository uses other Git storage. Select its owning module or absorb it first.") }
            let noRetainedConflict = directory.path == retained.resolvingSymlinksInPath().path ? true : try localAttributes(retained) == nil
            guard noRetainedConflict else { throw GitFailure("This name already has retained Git storage. Choose another unused module name for the existing repository.") }
            admin = directory; head = try await child.headPosition()
            guard head?.hash != nil else { throw GitFailure("The existing repository needs a commit before becoming a submodule.") }
        case .archiveAndClone:
            let empty = attributes == nil ? true : attributes?[.type] as? FileAttributeType == .typeDirectory ? try FileManager.default.contentsOfDirectory(atPath: working.path).isEmpty : false
            guard empty, try localAttributes(retained)?[.type] as? FileAttributeType == .typeDirectory else { throw GitFailure("Fresh replacement requires retained Git data and a new or empty destination.") }
            try await requireRetainedModuleUnclaimed(retained)
            admin = retained
        case .retainedRepository:
            let empty = attributes == nil ? true : attributes?[.type] as? FileAttributeType == .typeDirectory ? try FileManager.default.contentsOfDirectory(atPath: working.path).isEmpty : false
            guard empty else { throw GitFailure("Retained Git data can only populate a new or empty directory.") }
            guard try localAttributes(retained)?[.type] as? FileAttributeType == .typeDirectory else { throw GitFailure("No retained Git repository exists for this module name.") }
            try await requireRetainedModuleUnclaimed(retained, target: working)
            let args = ["--git-dir=" + retained.path, "--work-tree=" + root.path]
            let hash = try await GitProcess.run(args + ["rev-parse", "--verify", "HEAD^{commit}"], at: root).text.trimmingCharacters(in: .newlines)
            let branch = try await GitProcess.run(args + ["symbolic-ref", "-q", "HEAD"], at: root, allowed: [0, 1])
            guard try await GitProcess.run(args + ["ls-files", "--unmerged", "-z"], at: root).data.isEmpty else { throw GitFailure("The retained index has conflicts. Recover its saved repository and resolve them before reuse.") }
            admin = retained; head = HeadPosition(branch: branch.status == 0 ? branch.text.trimmingCharacters(in: .newlines) : "HEAD", hash: hash)
        }
        return SubmoduleDirectoryState(mode: mode, workingDigest: try managementDirectoryDigest(working), gitDirectory: admin?.path, storageDigest: try admin.map { try managementDirectoryDigest($0) } ?? nil, head: head)
    }
    func addReusedSubmodule(_ plan: SubmoduleAdditionPlan) async throws {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        guard plan.repository == root.path, try await headPosition() == plan.head, try await submoduleAddIndex() == plan.index, try submoduleConfigurationData() == plan.configuration,
              try await inspectSubmoduleDirectory(path: plan.path, name: plan.name, mode: plan.directory.mode) == plan.directory else { throw GitFailure("The parent or reused directory changed after preview.") }
        try await requireIdleManagement(); try await requireGitmodulesUnmodified()
        let working = try validateLocalPath(plan.path), admin = plan.directory.gitDirectory.map { URL(fileURLWithPath: $0) }
        let pointers: [RepositoryPointer]
        if plan.directory.mode == .existingRepository { pointers = try await GitRepository.open(working).repositoryPointers(includeRoot: true, allowedStorage: commonDirectory()) } else { pointers = [] }
        let metadata = [root.appendingPathComponent(".gitmodules").path, try await localIndexURL().path, try await commonDirectory().appendingPathComponent("config").path]
        let extras = admin.map { $0.path.hasPrefix(working.path + "/") ? [] : [$0.path] } ?? []
        let backup = try await beginRelatedBackup(title: "Reuse Submodule · " + plan.path, kind: "submodule", original: working.path, current: working.path, pointers: pointers, extraFiles: metadata, extraDirectories: extras)
        do {
            guard try await headPosition() == plan.head, try await submoduleAddIndex() == plan.index else { throw GitFailure("The parent changed while saving reuse recovery data.") }
            if plan.directory.mode == .emptyDirectory || plan.directory.mode == .archiveAndClone {
                if try localAttributes(working) != nil {
                    guard Darwin.rmdir(working.path) == 0 else { throw GitFailure("The reuse directory is no longer empty. Its contents were kept.") }
                }
                if plan.directory.mode == .archiveAndClone, let admin { try FileManager.default.removeItem(at: admin) }
                _ = try await GitProcess.run(["--literal-pathspecs"] + moduleTransportOptions(plan.allowLocalTransport) + ["submodule", "add", "--name", plan.name] + (plan.branch.isEmpty ? [] : ["-b", plan.branch]) + ["--", plan.source, plan.path], at: root, timeout: 120)
            } else {
                guard let admin, let hash = plan.directory.head?.hash else { throw GitFailure("The reused repository has no verified HEAD.") }
                if plan.directory.mode == .retainedRepository {
                    try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
                    try Data(("gitdir: " + admin.path + "\n").utf8).write(to: working.appendingPathComponent(".git"), options: .withoutOverwriting)
                    _ = try await GitProcess.run(["config", "--file", admin.appendingPathComponent("config").path, "core.worktree", working.path], at: root)
                    let args = ["--git-dir=" + admin.path, "--work-tree=" + working.path]
                    if try readLocalIndex(admin.appendingPathComponent("index")) == nil { _ = try await GitProcess.run(args + ["read-tree", "HEAD"], at: root) }
                    _ = try await GitProcess.run(args + ["checkout-index", "--all", "--prefix=" + working.path + "/"], at: root, timeout: 120)
                }
                _ = try await GitProcess.run(["config", "--file", ".gitmodules", "submodule." + plan.name + ".path", plan.path], at: root)
                _ = try await GitProcess.run(["config", "--file", ".gitmodules", "submodule." + plan.name + ".url", plan.source], at: root)
                if !plan.branch.isEmpty { _ = try await GitProcess.run(["config", "--file", ".gitmodules", "submodule." + plan.name + ".branch", plan.branch], at: root) }
                _ = try await GitProcess.run(["config", "--local", "submodule." + plan.name + ".url", plan.source], at: root)
                _ = try await GitProcess.run(["config", "--local", "submodule." + plan.name + ".active", "true"], at: root)
                _ = try await GitProcess.run(["update-index", "--add", "--cacheinfo", "160000," + hash + "," + plan.path], at: root)
                _ = try await GitProcess.run(["add", "--", ".gitmodules"], at: root)
            }
            try await finishRelatedBackup(backup)
        } catch { try? await finishRelatedBackup(backup, error: error); throw error }
    }
}
