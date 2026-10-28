import Foundation

// The entire mutable scan stays on one actor, including recursive module discovery.
actor PointerRepairBuilder {
    let repository: GitRepository
    let main: URL
    let common: URL
    let previousMainPath: String?
    let locations: [String: String]
    let replaceBrokenMarkers: Bool
    var oldMain: String?
    var before: [String: ManagementFile] = [:]
    var desired: [String: Data] = [:]
    var targets: [PointerRepairTarget] = []
    var usedAdmins = Set<String>()
    var usedRoots = Set<String>()
    init(repository: GitRepository, main: URL, previousMainPath: String?, locations: [String: String], replaceBrokenMarkers: Bool) {
        self.repository = repository; self.main = main; self.common = main.appendingPathComponent(".git")
        self.previousMainPath = previousMainPath; self.locations = locations; self.replaceBrokenMarkers = replaceBrokenMarkers
    }
    func build() async throws -> PointerRepairPlan {
        guard try repository.localAttributes(common)?[.type] as? FileAttributeType == .typeDirectory else { throw GitFailure("Select the main repository folder containing its .git directory.") }
        try repository.checkManagementAncestors(common)
        let adminBase = common.appendingPathComponent("worktrees")
        let admins = ((try? FileManager.default.contentsOfDirectory(at: adminBase, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        oldMain = previousMainPath.map(repository.worktreePath)
        if oldMain == nil {
            var candidates = Set<String>()
            for admin in admins {
                guard let data = try repository.readLocalIndex(admin.appendingPathComponent("gitdir")), var path = String(data: data, encoding: .utf8) else { continue }
                if path.last == "\n" { path.removeLast() }
                let oldWorking = URL(fileURLWithPath: path).deletingLastPathComponent()
                let chosen = locations["worktree:" + admin.lastPathComponent].map { URL(fileURLWithPath: $0) } ?? oldWorking
                if let target = try repository.readGitPointer(chosen.appendingPathComponent(".git")), target.lastPathComponent == admin.lastPathComponent, target.deletingLastPathComponent().lastPathComponent == "worktrees" {
                    let oldCommon = target.deletingLastPathComponent().deletingLastPathComponent()
                    if oldCommon.lastPathComponent == ".git", repository.worktreePath(oldCommon.path) != repository.worktreePath(common.path) { candidates.insert(repository.worktreePath(oldCommon.deletingLastPathComponent().path)) }
                }
            }
            guard candidates.count <= 1 else { throw GitFailure("Several previous main paths were found. Supply the original main repository path explicitly.") }
            oldMain = candidates.first
        }

        if try await repository.configuredWorktree(common) != nil { try await config(common.appendingPathComponent("config"), values: ["core.worktree": main.path]) }
        let mainWorktreeConfig = common.appendingPathComponent("config.worktree")
        if try repository.localAttributes(mainWorktreeConfig) != nil { try await config(mainWorktreeConfig, values: ["core.worktree": main.path]) }
        targets.append(PointerRepairTarget(id: "main", title: localized("Main Repository"), workingPath: main.path, gitDirectory: common.path, missing: false, mappingChanged: false))
        usedAdmins.insert(common.path); usedRoots.insert(main.path)
        try await modules(working: main, admin: common, key: "module:main", depth: 0)
        for admin in admins {
            guard try repository.localAttributes(admin)?[.type] as? FileAttributeType == .typeDirectory else { throw GitFailure("Worktree storage contains an invalid directory.") }
            let id = "worktree:" + admin.lastPathComponent
            guard let data = try repository.readLocalIndex(admin.appendingPathComponent("gitdir")), var text = String(data: data, encoding: .utf8) else { throw GitFailure("A worktree has no readable registration pointer.") }
            if text.last == "\n" { text.removeLast() }
            let original = URL(fileURLWithPath: text).deletingLastPathComponent().path
            let working = URL(fileURLWithPath: repository.worktreePath(locations[id] ?? mapped(original)))
            try change(admin.appendingPathComponent("gitdir"), Data((working.appendingPathComponent(".git").path + "\n").utf8))
            let commondir = admin.appendingPathComponent("commondir")
            if let data = try repository.readLocalIndex(commondir), String(data: data, encoding: .utf8)?.hasPrefix("/") == true { try change(commondir, Data((common.path + "\n").utf8)) }
            let missing = try repository.localAttributes(working) == nil
            targets.append(PointerRepairTarget(id: id, title: localized("Worktree · \(working.lastPathComponent)"), workingPath: working.path, gitDirectory: admin.path, missing: missing, mappingChanged: false))
            if missing { continue }
            guard usedRoots.insert(working.path).inserted else { throw GitFailure("Two worktree entries point at the same folder.") }
            try repository.checkManagementAncestors(working)
            let embedded = try await checkMarker(working, admin: admin)
            guard !embedded else { throw GitFailure("A linked worktree cannot replace an embedded repository.") }
            try change(working.appendingPathComponent(".git"), Data(("gitdir: " + admin.path + "\n").utf8))
            let worktreeConfig = admin.appendingPathComponent("config.worktree")
            if try repository.localAttributes(worktreeConfig) != nil { try await config(worktreeConfig, values: ["core.worktree": working.path]) }
            try await modules(working: working, admin: admin, key: "module:" + id, depth: 0)
        }
        let files = before.values.sorted { $0.path < $1.path }
        return PointerRepairPlan(mainRoot: main, targets: targets, common: common, before: files, after: files.map { ManagementFile(path: $0.path, data: desired[$0.path]) })

    }
    func mapped(_ path: String) -> String { oldMain.map { repository.relocatedPath(repository.worktreePath(path), from: $0, to: main.path) } ?? repository.worktreePath(path) }
    func change(_ url: URL, _ data: Data) throws {
        let file = try repository.rawManagementFile(url)
        if before[file.path] == nil { before[file.path] = file }
        desired[file.path] = data
    }
    func config(_ file: URL, values: [String: String]) async throws {
        let original = try repository.rawManagementFile(file)
        try change(file, await repository.editedConfiguration(original.data, values: values))
    }
    func checkMarker(_ working: URL, admin: URL) async throws -> Bool {
        let marker = working.appendingPathComponent(".git")
        guard let type = try repository.localAttributes(marker)?[.type] as? FileAttributeType else {
            guard replaceBrokenMarkers else { throw GitFailure("A .git marker is missing. Review and enable replacement of broken markers.") }; return false
        }
        if type == .typeDirectory { return true }
        guard type == .typeRegular else { throw GitFailure("A Git marker was replaced by a link or special file.") }
        if let original = try repository.readGitPointer(marker) {
            if repository.worktreePath(original.path) == repository.worktreePath(admin.path) { return false }
            if try repository.localAttributes(original) != nil { throw GitFailure("The pointer still targets live Git storage elsewhere. This repair cannot take over another repository.") }
            if mapped(original.path) == repository.worktreePath(admin.path) { return false }
        }
        guard replaceBrokenMarkers else { throw GitFailure("An invalid Git pointer needs explicit replacement in the repair preview.") }
        return false
    }
    func modules(working: URL, admin: URL, key: String, depth: Int) async throws {
        guard depth < 16, targets.count < 512 else { throw GitFailure("Pointer repair supports 16 levels / 512 repositories.") }
        let modulesFile = working.appendingPathComponent(".gitmodules")
        guard let moduleData = try repository.rawManagementFile(modulesFile).data else { return }
        let parsed = try repository.configFields(await GitProcess.run(["config", "--null", "--no-includes", "--file", modulesFile.path, "--list"], at: main).data)
        var mapping: [String: String] = [:]
        for field in parsed.keys.sorted() where field.hasPrefix("submodule.") && field.hasSuffix(".path") {
            let name = String(field.dropFirst(10).dropLast(5)), originalPath = parsed[field]!
            try repository.validateModuleName(name); _ = try await repository.validateLocalPath(originalPath, in: working)
            let childKey = key + "/" + name
            let destination = locations[childKey].map { URL(fileURLWithPath: $0) } ?? working.appendingPathComponent(originalPath)
            let child = URL(fileURLWithPath: repository.worktreePath(destination.path))
            guard child.path.hasPrefix(working.path + "/") else { throw GitFailure("A repaired module must stay inside its parent working directory.") }
            let relative = String(child.path.dropFirst(working.path.count + 1)); _ = try await repository.validateLocalPath(relative, in: working)
            var childAdmin = admin.appendingPathComponent("modules/" + name)
            if try repository.localAttributes(child.appendingPathComponent(".git"))?[.type] as? FileAttributeType == .typeDirectory { childAdmin = child.appendingPathComponent(".git") }
            else if let pointer = try repository.readGitPointer(child.appendingPathComponent(".git")) {
                let candidate = URL(fileURLWithPath: mapped(pointer.path))
                if try repository.localAttributes(candidate) != nil, candidate.path.hasPrefix(common.path + "/") || candidate.path.hasPrefix(admin.path + "/modules/") { childAdmin = candidate }
            }
            childAdmin = URL(fileURLWithPath: repository.worktreePath(childAdmin.path))
            let available = try repository.localAttributes(child) != nil
            let retained = try repository.localAttributes(childAdmin) != nil
            if !available || !retained {
                targets.append(PointerRepairTarget(id: childKey, title: localized("Submodule · \(name)"), workingPath: child.path, gitDirectory: childAdmin.path, missing: true, mappingChanged: relative != originalPath))
                if relative != originalPath { throw GitFailure("A relocated module needs its retained Git data and working directory before updating the mapping.") }
                continue
            }
            guard usedAdmins.insert(childAdmin.path).inserted, usedRoots.insert(child.path).inserted else { throw GitFailure("Two repair targets claim the same repository or working directory.") }
            try await repository.requireRetainedModuleUnclaimed(childAdmin, target: child, inspectNested: false)
            // An existing owner at the original path is valid only when that is the selected path.
            let embedded = try await checkMarker(child, admin: childAdmin)
            _ = try await GitProcess.run(["--git-dir=" + childAdmin.path, "--work-tree=" + child.path, "rev-parse", "--verify", "HEAD^{commit}"], at: main)
            if !embedded { try change(child.appendingPathComponent(".git"), Data(("gitdir: " + childAdmin.path + "\n").utf8)) }
            try await config(childAdmin.appendingPathComponent("config"), values: ["core.worktree": child.path])
            targets.append(PointerRepairTarget(id: childKey, title: localized("Submodule · \(name)"), workingPath: child.path, gitDirectory: childAdmin.path, missing: false, mappingChanged: relative != originalPath))
            if relative != originalPath { mapping[originalPath] = relative }
            try await modules(working: child, admin: childAdmin, key: childKey, depth: depth + 1)
        }
        if !mapping.isEmpty {
            for file in try await repository.repairModuleMappings(working: working, admin: admin, original: moduleData, fields: parsed, mapping: mapping) { try change(URL(fileURLWithPath: file.path), file.data!) }
        }
    }
}
