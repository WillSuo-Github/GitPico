import Foundation

public struct ManagedSubmodule: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let path: String
    public let url: String
    public let configuredURL: String?
    public let branch: String?
    public let recordedHash: String?
    public let head: String?
    public let gitDirectory: String?
    public let initialized: Bool
    public let dirty: Bool
    public let conflicted: Bool
    public let diagnostic: String?
    let configuration: Data?
    public var status: String {
        if conflicted { return localized("Gitlink conflict") }
        if let diagnostic { return diagnostic }
        if !initialized { return localized("Not initialized") }
        if dirty { return localized("Local changes") }
        if head != recordedHash { return localized("Different revision") }
        return localized("Up to date")
    }
}
private struct SubmoduleDefinition: Sendable { let name: String; let path: String; let url: String; let branch: String?; let localURL: String?; let hash: String?; let conflicted: Bool }
public enum SubmoduleOperation: String, CaseIterable, Sendable {
    case forceDeinitialize = "Force Deinitialize (Keep Backup)", forceRemove = "Force Remove (Keep Backup)", archiveStorage = "Archive Retained Git Storage", initialize = "Initialize / Checkout Recorded Version", update = "Update to Recorded Version", fetch = "Fetch", sync = "Synchronize URLs", checkout = "Checkout Revision", setURL = "Change URL", move = "Move Submodule", repair = "Repair Git Configuration", deinitialize = "Deinitialize", remove = "Remove Submodule"
}
public struct SubmodulePlan: Sendable {
    public let module: ManagedSubmodule
    public let operation: SubmoduleOperation
    public let value: String
    public let recursive: Bool
    public let allowLocalTransport: Bool
    public let head: HeadPosition
    let repository: String
    let index: Data?
}
public struct SubmoduleAdditionPlan: Sendable {
    public let source: String
    public let path: String
    public let name: String
    public let branch: String
    public let allowLocalTransport: Bool
    public let head: HeadPosition
    let index: Data?
    let configuration: Data?
    let repository: String
    let directory: SubmoduleDirectoryState
}
struct SubmoduleManagementBackup: Codable {
    let id: UUID
    let date: Date
    let repository: String
    let module: ManagedSubmodule
    let operation: String
    let index: Data?
    let gitmodules: Data?
    let localConfig: Data?
}

extension GitRepository {
    nonisolated func validateModuleName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), name.count <= 512, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw GitFailure("Invalid submodule name.") }
        try validateInspectionPath(name)
        guard !name.components(separatedBy: "/").contains(where: { $0.lowercased() == ".git" }) else { throw GitFailure("Invalid submodule name.") }
    }
    func submoduleConfigurationData() throws -> Data? {
        let file = try validateLocalPath(".gitmodules")
        guard let attributes = try localAttributes(file) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576 else { throw GitFailure(".gitmodules must be a regular file under 1 MB.") }
        return try Data(contentsOf: file)
    }
    nonisolated func configFields(_ data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { throw GitFailure("Submodule configuration must use UTF-8.") }
        var result: [String: String] = [:]
        for entry in text.components(separatedBy: "\0") where !entry.isEmpty {
            guard let split = entry.firstIndex(of: "\n") else { throw GitFailure("Invalid submodule configuration field.") }
            let key = String(entry[..<split])
            guard result[key] == nil else { throw GitFailure("Duplicate submodule configuration keys require manual repair.") }
            result[key] = String(entry[entry.index(after: split)...])
        }
        return result
    }
    public func managedSubmodules() async throws -> [ManagedSubmodule] {
        let configuration = try submoduleConfigurationData()
        let config: [String: String]
        if configuration != nil { config = try configFields(await GitProcess.run(["config", "--null", "--no-includes", "--file", ".gitmodules", "--list"], at: root).data) } else { config = [:] }
        let local = try configFields(await GitProcess.run(["config", "--local", "--null", "--get-regexp", "^submodule\\..*\\.url$"], at: root, allowed: [0, 1]).data)
        let entries = try await GitProcess.run(["ls-files", "--stage", "-z", "--"], at: root).data.split(separator: 0)
        var hashes: [String: String] = [:], conflicts: Set<String> = []
        for entry in entries {
            guard let tab = entry.firstIndex(of: 9), let path = String(data: entry[(tab + 1)...], encoding: .utf8) else { throw GitFailure("Submodule paths must use UTF-8.") }
            let fields = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            if fields.count == 3 && fields[0] == "160000" {
                if fields[2] == "0" { hashes[path] = String(fields[1]) } else { conflicts.insert(path) }
            }
        }
        var definitions: [SubmoduleDefinition] = [], known: Set<String> = []
        for key in config.keys.sorted() where key.hasPrefix("submodule.") && key.hasSuffix(".path") {
            let name = String(key.dropFirst(10).dropLast(5)), path = config[key]!
            try validateModuleName(name); _ = try validateLocalPath(path)
            guard known.insert(path).inserted else { throw GitFailure("Multiple submodule entries use the same path.") }
            definitions.append(SubmoduleDefinition(name: name, path: path, url: config["submodule." + name + ".url"] ?? "", branch: config["submodule." + name + ".branch"], localURL: local["submodule." + name + ".url"], hash: hashes[path], conflicted: conflicts.contains(path)))
        }
        for path in Set(hashes.keys).union(conflicts).subtracting(known).sorted() {
            _ = try validateLocalPath(path)
            definitions.append(SubmoduleDefinition(name: path, path: path, url: "", branch: nil, localURL: nil, hash: hashes[path], conflicted: conflicts.contains(path)))
        }
        guard definitions.count <= 256 else { throw GitFailure("Submodule management supports up to 256 direct modules.") }
        return try await withThrowingTaskGroup(of: ManagedSubmodule.self) { group in
            var iterator = definitions.makeIterator(), values: [ManagedSubmodule] = []
            for _ in 0..<min(8, definitions.count) { if let definition = iterator.next() { group.addTask { try await self.inspectSubmodule(definition, configuration: configuration) } } }
            while let value = try await group.next() {
                values.append(value)
                if let definition = iterator.next() { group.addTask { try await self.inspectSubmodule(definition, configuration: configuration) } }
            }
            return values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }
    private func inspectSubmodule(_ definition: SubmoduleDefinition, configuration: Data?) async throws -> ManagedSubmodule {
        let url = try validateLocalPath(definition.path), marker = url.appendingPathComponent(".git")
        let attributes = try localAttributes(marker)
        var head: String?, directory: String?, dirty = false, diagnostic: String?
        let initialized = attributes != nil
        if let attributes {
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw GitFailure("A submodule .git marker contains a symbolic link.") }
            do {
                let child = try await GitRepository.open(url)
                guard child.root.path == url.resolvingSymlinksInPath().path else { throw GitFailure("The submodule points at another working tree.") }
                directory = URL(fileURLWithPath: try gitPathOutput(await GitProcess.run(["rev-parse", "--absolute-git-dir"], at: url))).resolvingSymlinksInPath().path
                let status = try await GitProcess.run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all", "--ignored=matching", "--ignore-submodules=none"], at: url).text.components(separatedBy: "\0")
                head = status.first(where: { $0.hasPrefix("# branch.oid ") }).map { String($0.dropFirst(13)) }
                if head == "(initial)" { head = nil }
                dirty = status.contains { !$0.isEmpty && !$0.hasPrefix("# ") }
            } catch { diagnostic = localized("Invalid Git configuration: \(error.localizedDescription)") }
        }
        if definition.url.isEmpty { diagnostic = localized("Missing .gitmodules mapping") }
        return ManagedSubmodule(name: definition.name, path: definition.path, url: definition.url, configuredURL: definition.localURL, branch: definition.branch, recordedHash: definition.hash, head: head, gitDirectory: directory, initialized: initialized, dirty: dirty, conflicted: definition.conflicted, diagnostic: diagnostic, configuration: configuration)
    }
    public func checkedSubmodule(_ expected: ManagedSubmodule) async throws -> GitRepository {
        try await requireSubmodule(expected)
        guard expected.initialized, expected.gitDirectory != nil, expected.head != nil, expected.diagnostic == nil else { throw GitFailure("Initialize or repair this submodule before opening it.") }
        let directory = try validateLocalPath(expected.path), child = try await GitRepository.open(directory)
        guard child.root.path == directory.resolvingSymlinksInPath().path else { throw GitFailure("The submodule path no longer refers to its own working tree.") }
        return child
    }
    func requireSubmodule(_ expected: ManagedSubmodule) async throws {
        guard try await managedSubmodules().first(where: { $0.name == expected.name }) == expected else { throw GitFailure("Submodule configuration, revision or local state changed. Refresh its preview.") }
    }
    func submoduleStorageDirectory() async throws -> URL {
        URL(fileURLWithPath: try gitPathOutput(await GitProcess.run(["rev-parse", "--path-format=absolute", "--git-path", "modules"], at: root))).resolvingSymlinksInPath()
    }
    func moduleTransportOptions(_ allowLocal: Bool) -> [String] {
        ["-c", "protocol.allow=never", "-c", "protocol.https.allow=always", "-c", "protocol.http.allow=always", "-c", "protocol.ssh.allow=always", "-c", "protocol.git.allow=always", "-c", "protocol.ext.allow=never", "-c", "protocol.file.allow=" + (allowLocal ? "always" : "never")]
    }
    func validateModuleURL(_ url: String, allowLocal: Bool) throws {
        guard !url.isEmpty, !url.hasPrefix("-"), !url.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !url.contains("::") else { throw GitFailure("Choose a standard HTTPS/SSH/Git URL or an explicitly allowed local Git path.") }
        if url.contains("://") {
            guard let scheme = URLComponents(string: url)?.scheme?.lowercased(), ["http", "https", "ssh", "git", "file"].contains(scheme) else { throw GitFailure("Custom transport helpers are not supported.") }
            if scheme == "file", !allowLocal { throw GitFailure("Enable local file transport for this reviewed operation.") }
        } else if url.hasPrefix("./") || url.hasPrefix("../") {
            // Git resolves relative submodule URLs against the parent's remote.
            // The per-command protocol policy still refuses file transport unless opted in.
        } else if !url.hasPrefix("/"), !url.hasPrefix("."), url.contains(":") {
            // Git's scp-style host:path syntax uses SSH without a URL scheme.
        } else if !allowLocal { throw GitFailure("Enable local file transport for this reviewed operation.") }

    }
    func requireGitmodulesUnmodified() async throws {
        let status = try await GitProcess.run(["status", "--porcelain=v1", "-z", "--", ".gitmodules"], at: root)
        guard !GitParser.status(status.data).contains(where: { $0.isUnstaged || $0.isConflicted }) else { throw GitFailure("Stage or commit your existing .gitmodules edits before changing submodule configuration.") }
    }
    func requireModuleTreeClean(_ module: ManagedSubmodule, recursive: Bool, requireRecorded: Bool = false, depth: Int = 0) async throws {
        guard depth < 16, !module.conflicted else { throw GitFailure("Resolve gitlink conflicts or reduce submodule nesting first.") }
        if module.initialized {
            let child = try await checkedSubmodule(module); try await requireCleanTreeForManagement(child)
            if requireRecorded, module.head != module.recordedHash { throw GitFailure("Record this submodule's current revision in the parent before removing or deinitializing it.") }
            if recursive { for nested in try await child.managedSubmodules() { try await child.requireModuleTreeClean(nested, recursive: true, requireRecorded: requireRecorded, depth: depth + 1) } }
        } else {
            let directory = try validateLocalPath(module.path)
            if try localAttributes(directory) != nil, !(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) { throw GitFailure("The uninitialized submodule folder contains local files. Repair it or move them aside first.") }
        }
    }
    public func previewSubmodule(_ module: ManagedSubmodule, operation: SubmoduleOperation, value: String = "", recursive: Bool = false, allowLocalTransport: Bool = false) async throws -> SubmodulePlan {
        try await requireIdleManagement(); try await requireSubmodule(module)
        guard !module.conflicted || [.forceDeinitialize, .forceRemove].contains(operation) else { throw GitFailure("Resolve the parent gitlink conflict first.") }
        var target = value
        switch operation {
        case .initialize, .update:
            try validateModuleURL(module.configuredURL ?? module.url, allowLocal: allowLocalTransport)
            try await requireModuleTreeClean(module, recursive: recursive)
        case .checkout:
            let child = try await checkedSubmodule(module); try await requireModuleTreeClean(module, recursive: false)
            target = try await child.verifiedCommit(value)
        case .fetch: _ = try await checkedSubmodule(module)
        case .deinitialize, .remove:
            try await requireModuleTreeClean(module, recursive: true, requireRecorded: true)
            try await requireGitmodulesUnmodified()
            if module.initialized {
                let common = try await submoduleStorageDirectory().path + "/"
                guard module.gitDirectory?.hasPrefix(common) == true else { throw GitFailure("Repair/absorb the embedded submodule Git directory before removal.") }
            }
            if operation == .remove, (try await headPosition()).hash != nil {
                let staged = try await GitProcess.run(["diff", "--cached", "--quiet", "--", module.path], at: root, allowed: [0, 1])
                guard staged.status == 0 else { throw GitFailure("Commit or unstage the parent gitlink change before removing the submodule.") }
            }
        case .forceDeinitialize, .forceRemove, .archiveStorage:
            try await requireGitmodulesUnmodified()
            if module.initialized { _ = try await checkedSubmodule(module) }
            else { _ = try validateLocalPath(module.path) }
            let storage = try await submoduleStorageDirectory().appendingPathComponent(module.name)
            if operation == .archiveStorage {
                guard !module.initialized, try localAttributes(storage) != nil else { throw GitFailure("Deinitialize this module before archiving its retained Git storage.") }
                try await requireRetainedModuleUnclaimed(storage)
            }
        case .setURL: try validateModuleURL(value, allowLocal: allowLocalTransport); try await requireGitmodulesUnmodified()
        case .move:
            try await requireModuleTreeClean(module, recursive: true); try await requireGitmodulesUnmodified()
            _ = try validateLocalPath(value)
            guard value != module.path, !value.hasPrefix(module.path + "/"), try localAttributes(root.appendingPathComponent(value)) == nil else { throw GitFailure("Choose a new non-overlapping submodule path.") }

        case .sync: try await requireGitmodulesUnmodified()
        case .repair: break
        }
        return SubmodulePlan(module: module, operation: operation, value: target, recursive: recursive, allowLocalTransport: allowLocalTransport, head: try await headPosition(), repository: root.path, index: try readLocalIndex(try await localIndexURL()))
    }
    public func applySubmodule(_ plan: SubmodulePlan) async throws {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        guard plan.repository == root.path, try await headPosition() == plan.head, try readLocalIndex(try await localIndexURL()) == plan.index else { throw GitFailure("The parent repository or index changed. Reopen the submodule preview.") }
        _ = try await previewSubmodule(plan.module, operation: plan.operation, value: plan.value, recursive: plan.recursive, allowLocalTransport: plan.allowLocalTransport)
        if plan.operation == .fetch { try await executeSubmodule(plan); return }
        let original = try validateLocalPath(plan.module.path).path
        let current = plan.operation == .move ? try validateLocalPath(plan.value).path : original
        let pointers: [RepositoryPointer]
        if plan.module.initialized, plan.module.diagnostic == nil { pointers = try await checkedSubmodule(plan.module).repositoryPointers(includeRoot: true, allowedStorage: commonDirectory()) } else { pointers = [] }
        let storage = try await submoduleStorageDirectory().appendingPathComponent(plan.module.name)
        let files = [root.appendingPathComponent(".gitmodules").path, try await localIndexURL().path, try await commonDirectory().appendingPathComponent("config").path] + ["config", "HEAD", "index"].map { storage.appendingPathComponent($0).path }
        let force = [.forceDeinitialize, .forceRemove, .archiveStorage].contains(plan.operation)
        let extraDirectories: [String]
        if force, try localAttributes(storage) != nil { extraDirectories = [storage.path] } else { extraDirectories = [] }
        let backup = try await beginRelatedBackup(title: plan.operation.title + " · " + plan.module.path, kind: "submodule", original: original, current: current, pointers: pointers, extraFiles: files, extraDirectories: extraDirectories)
        do { try await executeSubmodule(plan); try await finishRelatedBackup(backup) }
        catch { try? await finishRelatedBackup(backup, error: error); throw error }
    }
    func executeSubmodule(_ plan: SubmodulePlan) async throws {
        guard plan.repository == root.path, try await headPosition() == plan.head, try readLocalIndex(try await localIndexURL()) == plan.index else { throw GitFailure("The parent repository or index changed. Reopen the submodule preview.") }
        _ = try await previewSubmodule(plan.module, operation: plan.operation, value: plan.value, recursive: plan.recursive, allowLocalTransport: plan.allowLocalTransport)
        let module = plan.module, path = module.path, policy = moduleTransportOptions(plan.allowLocalTransport)

        if module.initialized, [.initialize, .update, .checkout, .deinitialize, .remove].contains(plan.operation), let hash = module.head {
            let child = try await checkedSubmodule(module); try await child.checkpoint(hash, id: UUID(), side: "submodule-before")
        }
        switch plan.operation {
        case .initialize, .update:
            _ = try await GitProcess.run(["--literal-pathspecs"] + policy + ["submodule", "update", "--init", "--checkout"] + (plan.recursive ? ["--recursive"] : []) + ["--", path], at: root, timeout: 120)
        case .fetch:
            let child = try await checkedSubmodule(module)
            _ = try await GitProcess.run(policy + ["fetch", "--all", plan.recursive ? "--recurse-submodules=on-demand" : "--no-recurse-submodules"], at: child.root, timeout: 120)
        case .checkout:
            let child = try await checkedSubmodule(module)
            _ = try await GitProcess.run(["-c", "submodule.recurse=false", "checkout", "--detach", plan.value, "--"], at: child.root)
        case .sync:
            _ = try await GitProcess.run(["--literal-pathspecs", "submodule", "sync"] + (plan.recursive ? ["--recursive"] : []) + ["--", path], at: root)
        case .setURL:
            _ = try await GitProcess.run(["--literal-pathspecs", "submodule", "set-url", "--", path, plan.value], at: root)
            _ = try await GitProcess.run(["add", "--", ".gitmodules"], at: root)
        case .move:
            if module.initialized { try await moveNestedSubmodule(module, to: plan.value) }
            else {
                let destination = try validateLocalPath(plan.value)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try await GitProcess.run(["--literal-pathspecs", "mv", "--", path, plan.value], at: root)
                _ = try await GitProcess.run(["add", "--", ".gitmodules"], at: root)
            }
        case .deinitialize:
            _ = try await GitProcess.run(["--literal-pathspecs", "submodule", "deinit", "--", path], at: root)
        case .remove:
            if module.initialized { _ = try await GitProcess.run(["--literal-pathspecs", "submodule", "deinit", "--", path], at: root) }
            _ = try await GitProcess.run(["rm", "--", path], at: root)
        case .forceDeinitialize, .forceRemove:
            if module.initialized, try localAttributes(root.appendingPathComponent(path + "/.git"))?[.type] as? FileAttributeType == .typeDirectory {
                _ = try await GitProcess.run(["--literal-pathspecs", "submodule", "absorbgitdirs", "--", path], at: root)
            }
            if module.initialized { _ = try await GitProcess.run(["--literal-pathspecs", "submodule", "deinit", "--force", "--", path], at: root) }
            else if try localAttributes(root.appendingPathComponent(path)) != nil { try FileManager.default.removeItem(at: try validateLocalPath(path)) }
            if plan.operation == .forceRemove { _ = try await GitProcess.run(["--literal-pathspecs", "rm", "--force", "--", path], at: root) }
        case .archiveStorage:
            let storage = try await submoduleStorageDirectory().appendingPathComponent(module.name)
            try checkManagementAncestors(storage)
            try FileManager.default.removeItem(at: storage)
        case .repair: try await repairSubmodule(module)
        }
    }
    func repairSubmodule(_ module: ManagedSubmodule) async throws {
        let directory = try validateLocalPath(module.path), marker = directory.appendingPathComponent(".git")
        if let attributes = try localAttributes(marker) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory || module.gitDirectory != nil else { throw GitFailure("The existing .git file points at an unavailable repository. Repair it manually before continuing.") }
            _ = try await GitProcess.run(["--literal-pathspecs", "submodule", "absorbgitdirs", "--", module.path], at: root)
        } else {
            try validateModuleName(module.name)
            let admin = try await submoduleStorageDirectory().appendingPathComponent(module.name).resolvingSymlinksInPath()
            let expected = try await submoduleStorageDirectory().path + "/"
            guard admin.path.hasPrefix(expected), FileManager.default.fileExists(atPath: admin.appendingPathComponent("HEAD").path) else { throw GitFailure("No retained Git directory was found. Initialize the submodule instead.") }
            let worktree = try gitPathOutput(await GitProcess.run(["--git-dir=" + admin.path, "config", "--get", "core.worktree"], at: root))
            let old = worktree.hasPrefix("/") ? URL(fileURLWithPath: worktree) : admin.appendingPathComponent(worktree)
            guard old.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path else { throw GitFailure("Retained Git metadata belongs to a different working directory.") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(("gitdir: " + admin.path + "\n").utf8).write(to: marker, options: .withoutOverwriting)
        }
    }
    public func previewSubmoduleAddition(source: String, path: String, name: String = "", branch: String = "", allowLocalTransport: Bool = false, directoryMode: SubmoduleDirectoryMode = .newDirectory) async throws -> SubmoduleAdditionPlan {
        try await requireIdleManagement(); try await requireGitmodulesUnmodified(); try validateModuleURL(source, allowLocal: allowLocalTransport)
        _ = try validateLocalPath(path); try validateModuleName(name.isEmpty ? path : name)
        let directory = try await inspectSubmoduleDirectory(path: path, name: name.isEmpty ? path : name, mode: directoryMode)
        guard !(try await managedSubmodules().contains { $0.path == path || $0.name == (name.isEmpty ? path : name) }) else { throw GitFailure("Choose a new path and unused submodule name.") }
        if !branch.isEmpty { try await validateReferenceName(branch) }
        if let reused = directory.head {
            guard branch.isEmpty || reused.branch == "refs/heads/" + branch else { throw GitFailure("Reuse preserves the existing branch and index. Choose its current branch or leave the branch field empty.") }
            let origin = try await GitProcess.run(["config", "--file", directory.gitDirectory! + "/config", "--get", "remote.origin.url"], at: root, allowed: [0, 1])
            let matchesOrigin = origin.status == 1 ? true : try gitPathOutput(origin) == source
            guard matchesOrigin else { throw GitFailure("The reused repository's origin differs from the reviewed URL. Use its existing URL, then change the module URL separately.") }
        }
        return SubmoduleAdditionPlan(source: source, path: path, name: name.isEmpty ? path : name, branch: branch, allowLocalTransport: allowLocalTransport, head: try await headPosition(), index: try readLocalIndex(try await localIndexURL()), configuration: try submoduleConfigurationData(), repository: root.path, directory: directory)
    }
    public func addSubmodule(_ plan: SubmoduleAdditionPlan) async throws {
        guard plan.repository == root.path, try submoduleConfigurationData() == plan.configuration else { throw GitFailure("The repository or .gitmodules changed. Reopen the addition preview.") }
        if plan.directory.mode != .newDirectory { try await addReusedSubmodule(plan); return }
        try await addSubmodule(source: plan.source, path: plan.path, name: plan.name, branch: plan.branch, allowLocalTransport: plan.allowLocalTransport, expectedHead: plan.head, expectedIndex: plan.index)
    }
    public func addSubmodule(source: String, path: String, name: String = "", branch: String = "", allowLocalTransport: Bool = false, expectedHead: HeadPosition, expectedIndex: Data?) async throws {
        try await requireIdleManagement(); try await requireGitmodulesUnmodified(); try validateModuleURL(source, allowLocal: allowLocalTransport)
        _ = try validateLocalPath(path); try validateModuleName(name.isEmpty ? path : name)
        guard try await headPosition() == expectedHead, try readLocalIndex(try await localIndexURL()) == expectedIndex, try localAttributes(root.appendingPathComponent(path)) == nil else { throw GitFailure("The parent index changed or destination exists. Refresh the preview.") }
        guard !(try await managedSubmodules().contains { $0.path == path || $0.name == (name.isEmpty ? path : name) }) else { throw GitFailure("This submodule name or path is already registered.") }
        if !branch.isEmpty { try await validateReferenceName(branch) }
        _ = try await GitProcess.run(["--literal-pathspecs"] + moduleTransportOptions(allowLocalTransport) + ["submodule", "add", "--name", name.isEmpty ? path : name] + (branch.isEmpty ? [] : ["-b", branch]) + ["--", source, path], at: root, timeout: 120)
    }
    public func submoduleAddIndex() async throws -> Data? { try readLocalIndex(try await localIndexURL()) }
}
