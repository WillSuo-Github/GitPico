import Foundation

extension GitRepository {
    public func references() async throws -> [Reference] {
        let result = try await GitProcess.run(["for-each-ref", "--sort=refname", "--format=%(refname)%00%(objectname)%00%(symref)%00%(upstream:short)%00%(HEAD)", "refs/heads", "refs/remotes", "refs/tags"], at: root)
        return GitParser.references(result.data)
    }

    func requireIdleManagement() async throws {
        guard try await currentOperation() == .none else { throw GitFailure("Finish or abort the current operation first.") }
    }

    func requireReference(_ reference: Reference) async throws {
        let actual = try await GitProcess.run(["show-ref", "--verify", "--hash", "--", reference.fullName], at: root, allowed: [0, 1, 128])
        guard actual.status == 0, actual.text.trimmingCharacters(in: .newlines) == reference.hash else { throw GitFailure("This reference changed outside the preview. Refresh before continuing.") }
    }

    func validateReferenceName(_ name: String, tag: Bool = false) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.utf8.contains(0), !name.hasPrefix("refs/"), !name.contains("\n") else { throw GitFailure("Enter a valid reference name.") }
        _ = try await GitProcess.run(["check-ref-format", (tag ? "refs/tags/" : "refs/heads/") + name], at: root)
    }

    func requireBranchNotInOtherWorktree(_ ref: Reference, allowCurrent: Bool) async throws {
        let current = try await headPosition()
        if !allowCurrent, current.branch == ref.fullName { throw GitFailure("Check out another branch before deleting this branch.") }
        let output = try await GitProcess.run(["worktree", "list", "--porcelain", "-z"], at: root).text
        var path = ""
        for item in output.components(separatedBy: "\0") {
            if item.hasPrefix("worktree ") { path = String(item.dropFirst(9)) }
            if item == "branch " + ref.fullName, URL(fileURLWithPath: path).resolvingSymlinksInPath() != root {
                throw GitFailure("This branch is checked out in another worktree: \(path)")
            }
        }
    }

    public func createBranch(_ name: String, at revision: String, checkout: Bool, upstream: String? = nil) async throws {
        try await requireIdleManagement(); try await validateReferenceName(name)
        let hash = try await verifiedCommit(revision)
        if let upstream {
            guard upstream.hasPrefix("refs/heads/") || upstream.hasPrefix("refs/remotes/") else { throw GitFailure("Choose a local or remote tracking branch.") }
            _ = try await verifiedCommit(upstream)
        }
        _ = try await GitProcess.run(["branch", "--no-track", "--", name, hash], at: root)
        if let upstream { _ = try await GitProcess.run(["branch", "--set-upstream-to=" + upstream, "--", name], at: root) }
        if checkout { _ = try await GitProcess.run(["switch", "--", name], at: root) }
    }

    public func renameBranch(_ ref: Reference, to name: String) async throws {
        guard ref.isLocal else { throw GitFailure("Only local branches can be renamed.") }
        try await requireIdleManagement(); try await validateReferenceName(name)
        try await requireBranchNotInOtherWorktree(ref, allowCurrent: true); try await requireReference(ref)
        _ = try await GitProcess.run(["branch", "-m", "--", ref.name, name], at: root)
        var organization = try await referenceOrganization()
        if organization.archived.remove(ref.fullName) != nil { organization.archived.insert("refs/heads/" + name) }
        if organization.pinned.remove(ref.fullName) != nil { organization.pinned.insert("refs/heads/" + name) }
        try await writeManagement(organization, name: "organization.json")
    }

    public func deleteBranch(_ ref: Reference, force: Bool = false) async throws {
        guard ref.isLocal else { throw GitFailure("Choose a local branch. Remote deletion has its own preview.") }
        try await requireIdleManagement(); try await requireBranchNotInOtherWorktree(ref, allowCurrent: false)
        try await requireReference(ref)
        if !force {
            let result = try await GitProcess.run(["merge-base", "--is-ancestor", ref.hash, "HEAD"], at: root, allowed: [0, 1])
            guard result.status == 0 else { throw GitFailure("This branch has commits not merged into HEAD. Review them or explicitly allow deletion of an unmerged branch.") }
        }
        _ = try await backupReference(fullName: ref.fullName, hash: ref.hash, title: localized("Deleted branch \(ref.name)"))
        _ = try await GitProcess.run(["update-ref", "-d", ref.fullName, ref.hash], at: root)
        _ = try await GitProcess.run(["config", "--local", "--remove-section", "branch." + ref.name], at: root, allowed: [0, 128, 5])
        var organization = try await referenceOrganization()
        organization.archived.remove(ref.fullName); organization.pinned.remove(ref.fullName)
        try await writeManagement(organization, name: "organization.json")
    }

    public func setUpstream(_ ref: Reference, to upstream: String?) async throws {
        guard ref.isLocal else { throw GitFailure("Choose a local branch.") }
        try await requireIdleManagement(); try await requireReference(ref)
        if let upstream {
            guard upstream != ref.fullName, upstream.hasPrefix("refs/heads/") || upstream.hasPrefix("refs/remotes/") else { throw GitFailure("Choose another local or remote branch.") }
            _ = try await verifiedCommit(upstream)
            _ = try await GitProcess.run(["branch", "--set-upstream-to=" + upstream, "--", ref.name], at: root)
        } else {
            _ = try await GitProcess.run(["branch", "--unset-upstream", "--", ref.name], at: root)
        }
    }

    public func setReferenceOrganization(_ ref: Reference, archived: Bool? = nil, pinned: Bool? = nil) async throws {
        guard ref.isLocal else { throw GitFailure("Choose a local branch.") }
        try await requireReference(ref)
        var value = try await referenceOrganization()
        if let archived { if archived { value.archived.insert(ref.fullName) } else { value.archived.remove(ref.fullName) } }
        if let pinned { if pinned { value.pinned.insert(ref.fullName) } else { value.pinned.remove(ref.fullName) } }
        try await writeManagement(value, name: "organization.json")
    }

    public func referenceOrganization() async throws -> ReferenceOrganization {
        try await readManagement(ReferenceOrganization.self, name: "organization.json") ?? ReferenceOrganization()
    }

    public func createTag(_ name: String, at revision: String, message: String = "", annotated: Bool = false, sign: Bool = false, signingKey: String = "") async throws {
        try await requireIdleManagement(); try await validateReferenceName(name, tag: true)
        let hash = try await verifiedCommit(revision)
        let annotation = annotated || sign || !message.isEmpty
        var args = ["tag"]
        if sign { args += signingKey.isEmpty ? ["-s"] : ["-u", signingKey] }
        else { args += annotation ? ["-a", "--no-sign"] : ["--no-sign"] }
        if annotation { args += ["-m", message.isEmpty ? name : message] }
        _ = try await GitProcess.run(args + ["--", name, hash], at: root, timeout: 120)
    }

    public func deleteTag(_ ref: Reference) async throws {
        guard ref.isTag else { throw GitFailure("Choose a local tag.") }
        try await requireIdleManagement(); try await requireReference(ref)
        _ = try await backupReference(fullName: ref.fullName, hash: ref.hash, title: localized("Deleted tag \(ref.name)"))
        _ = try await GitProcess.run(["update-ref", "-d", ref.fullName, ref.hash], at: root)
    }

    public func renameTag(_ ref: Reference, to name: String) async throws {
        guard ref.isTag else { throw GitFailure("Choose a local tag.") }
        try await requireIdleManagement(); try await validateReferenceName(name, tag: true); try await requireReference(ref)
        let commands = "start\ncreate refs/tags/\(name) \(ref.hash)\ndelete \(ref.fullName) \(ref.hash)\nprepare\ncommit\n"
        _ = try await GitProcess.run(["update-ref", "--stdin"], at: root, input: Data(commands.utf8))
    }

    func managementURL(_ name: String) async throws -> URL {
        let path = try await GitProcess.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root).text.trimmingCharacters(in: .newlines)
        let base = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let directory = base.appendingPathComponent("gitpico/management", isDirectory: true)
        var check = directory
        while check.path.hasPrefix(base.path + "/") {
            if let type = try? FileManager.default.attributesOfItem(atPath: check.path)[.type] as? FileAttributeType, type == .typeSymbolicLink { throw GitFailure("Management recovery storage contains a symbolic link.") }
            check.deleteLastPathComponent()
        }
        let url = directory.appendingPathComponent(name)
        if let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, type == .typeSymbolicLink { throw GitFailure("Management recovery file is a symbolic link.") }
        return url
    }

    func writeManagement<T: Encodable>(_ value: T, name: String) async throws {
        let url = try await managementURL(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    func readManagement<T: Decodable>(_ type: T.Type, name: String) async throws -> T? {
        let url = try await managementURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    @discardableResult func backupReference(fullName: String, hash: String, title: String) async throws -> ReferenceBackup {
        let record = ReferenceBackup(id: UUID(), fullName: fullName, hash: hash, title: title, date: Date())
        _ = try await GitProcess.run(["update-ref", "--create-reflog", "-m", title, "refs/gitpico/recovery/" + record.id.uuidString.lowercased(), hash], at: root)
        var backups = try await referenceBackups(); backups.insert(record, at: 0)
        try await writeManagement(backups, name: "backups.json")
        return record
    }

    public func referenceBackups() async throws -> [ReferenceBackup] { try await readManagement([ReferenceBackup].self, name: "backups.json") ?? [] }

    public func restoreReferenceBackup(_ record: ReferenceBackup, name: String) async throws {
        try await requireIdleManagement()
        guard try await referenceBackups().contains(where: { $0.id == record.id && $0.hash == record.hash && $0.fullName == record.fullName }) else { throw GitFailure("This recovery record is no longer available.") }
        if record.isStash {
            _ = try await GitProcess.run(["stash", "store", "-m", name.isEmpty ? record.title : name, record.hash], at: root)
        } else {
            try await validateReferenceName(name, tag: record.isTag)
            let target = (record.isTag ? "refs/tags/" : "refs/heads/") + name
            _ = try await GitProcess.run(["update-ref", target, record.hash, String(repeating: "0", count: record.hash.count)], at: root)
        }
    }
}

extension GitRepository {
    public func switchBranch(_ reference: Reference) async throws {
        guard reference.isLocal else { throw GitFailure("Choose a local branch to check out.") }
        try await requireIdleManagement()
        try await requireReference(reference)
        try await requireBranchNotInOtherWorktree(reference, allowCurrent: true)
        try await switchBranch(reference.name)
    }
}
