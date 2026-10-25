import Foundation
import Darwin

public struct PointerRepairTarget: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let workingPath: String
    public let gitDirectory: String
    public let missing: Bool
    public let mappingChanged: Bool
}
public struct PointerRepairPlan: Sendable {
    public let mainRoot: URL
    public let targets: [PointerRepairTarget]
    let common: URL
    let before: [ManagementFile]
    let after: [ManagementFile]
}
public struct PointerRepairBackup: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let mainPath: String
    public let targets: [PointerRepairTarget]
    public var state: String
    public var diagnostic: String?
    let before: [ManagementFile]
    let after: [ManagementFile]
}

extension GitRepository {
    nonisolated func rawManagementFile(_ url: URL) throws -> ManagementFile {
        let path = worktreePath(url.path); try checkManagementAncestors(URL(fileURLWithPath: path))
        return ManagementFile(path: path, data: try readLocalIndex(URL(fileURLWithPath: path)))
    }
    nonisolated func readGitPointer(_ marker: URL) throws -> URL? {
        guard let data = try readLocalIndex(marker), var text = String(data: data, encoding: .utf8), text.hasPrefix("gitdir: ") else { return nil }
        text.removeFirst(8); if text.last == "\n" { text.removeLast() }
        guard !text.isEmpty, !text.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: worktreePath(text.hasPrefix("/") ? text : marker.deletingLastPathComponent().appendingPathComponent(text).path))
    }
    func configuredWorktree(_ admin: URL) async throws -> String? {
        let output = try await GitProcess.run(["config", "--no-includes", "--file", admin.appendingPathComponent("config").path, "--get", "core.worktree"], at: root, allowed: [0, 1])
        guard output.status == 0 else { return nil }
        let text = try gitPathOutput(output)
        return worktreePath(text.hasPrefix("/") ? text : admin.appendingPathComponent(text).path)
    }
    func editedConfiguration(_ original: Data?, values: [String: String]) async throws -> Data {
        let scratch = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("config")
        try (original ?? Data()).write(to: file)
        for key in values.keys.sorted() { _ = try await GitProcess.run(["config", "--no-includes", "--file", file.path, key, values[key]!], at: scratch) }
        return try Data(contentsOf: file)
    }
    public func previewPointerRepair(previousMainPath: String? = nil, locations: [String: String] = [:], replaceBrokenMarkers: Bool = false) async throws -> PointerRepairPlan {
        try await PointerRepairBuilder(repository: self, main: URL(fileURLWithPath: worktreePath(root.path)), previousMainPath: previousMainPath, locations: locations, replaceBrokenMarkers: replaceBrokenMarkers).build()
    }
    func repairModuleMappings(working: URL, admin: URL, original: Data, fields: [String: String], mapping: [String: String]) async throws -> [ManagementFile] {
        let args = ["--git-dir=" + admin.path, "--work-tree=" + working.path], indexURL = admin.appendingPathComponent("index")
        guard let index = try readLocalIndex(indexURL) else { throw GitFailure("The parent module index is missing.") }
        let scratch = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent("index"); try index.write(to: temporary)
        _ = try await GitProcess.run(args + ["update-index", "--no-split-index"], at: root, indexFile: temporary)
        let staged = try await GitProcess.run(args + ["show", ":.gitmodules"], at: root, indexFile: temporary)
        guard staged.data == original else { throw GitFailure("Stage existing .gitmodules edits before repairing relocated module paths.") }
        var values: [String: String] = [:]
        for field in fields.keys where field.hasPrefix("submodule.") && field.hasSuffix(".path") { if let path = mapping[fields[field]!] { values[field] = path } }
        let data = try await editedConfiguration(original, values: values)
        let entries = try await GitProcess.run(args + ["ls-files", "--stage", "-z"], at: root, indexFile: temporary).data.split(separator: 0)
        var hashes: [String: String] = [:]
        for entry in entries {
            guard let tab = entry.firstIndex(of: 9), let path = String(data: entry[(tab + 1)...], encoding: .utf8) else { throw GitFailure("Invalid module index path.") }
            let parts = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            if parts.count == 3, parts[0] == "160000", parts[2] == "0" { hashes[path] = String(parts[1]) }
            for destination in mapping.values where path == destination || path.hasPrefix(destination + "/") || destination.hasPrefix(path + "/") { throw GitFailure("The repaired destination conflicts with an indexed path.") }
        }
        var commands = Data()
        for old in mapping.keys.sorted() {
            guard let hash = hashes[old] else { throw GitFailure("Resolve the parent's gitlink conflict before changing module paths.") }
            commands += Data(("0 " + String(repeating: "0", count: hash.count) + "\t" + old + "\0" + "160000 " + hash + "\t" + mapping[old]! + "\0").utf8)
        }
        let hash = try await GitProcess.run(args + ["hash-object", "-w", "--stdin"], at: root, input: data).text.trimmingCharacters(in: .newlines)
        commands += Data(("100644 " + hash + "\t.gitmodules\0").utf8)
        _ = try await GitProcess.run(args + ["update-index", "-z", "--index-info"], at: root, input: commands, indexFile: temporary)
        return [ManagementFile(path: working.appendingPathComponent(".gitmodules").path, data: data), ManagementFile(path: indexURL.path, data: try Data(contentsOf: temporary))]
    }
    func commitRepairFiles(before: [ManagementFile], after: [ManagementFile], allowPartial: Bool = false) throws {
        guard before.map(\.path) == after.map(\.path) else { throw GitFailure("Invalid pointer repair manifest.") }
        var leases: [(URL, Int32)] = []
        defer { for (file, descriptor) in leases { Darwin.close(descriptor); try? FileManager.default.removeItem(at: file) } }
        for (index, original) in before.enumerated() where original != after[index] {
            let url = URL(fileURLWithPath: original.path), current = try rawManagementFile(url)
            if allowPartial && current == after[index] { continue }
            guard current == original else { throw GitFailure("A pointer, configuration or index changed. Review the repair again.") }
            let lock = URL(fileURLWithPath: url.path + ".lock"); try checkManagementAncestors(lock)
            let descriptor = Darwin.open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw GitFailure("A Git metadata file is locked. The repair can be resumed after that operation ends.") }
            leases.append((lock, descriptor))
        }
        for (index, original) in before.enumerated() where original != after[index] {
            let url = URL(fileURLWithPath: original.path), current = try rawManagementFile(url)
            if allowPartial && current == after[index] { continue }
            guard current == original else { throw GitFailure("A metadata file changed during repair. Existing data was preserved.") }
            if let data = after[index].data { try data.write(to: url, options: .atomic) }
            else if try localAttributes(url) != nil { try FileManager.default.removeItem(at: url) }
        }
    }
    func acquireRawManagementLease(common: URL) throws -> Int32 {
        let file = common.appendingPathComponent("gitpico/management/related-management.lock")
        try checkManagementAncestors(file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw GitFailure("Unable to open the repository management lease.") }
        let lock: (Int32, Int32) -> Int32 = flock
        guard lock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw GitFailure("Another repository management operation is running.") }
        return descriptor
    }
    func savePointerRepair(_ record: PointerRepairBackup) throws {
        let directory = root.appendingPathComponent(".git/gitpico/pointer-repairs")
        try checkManagementAncestors(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(record.id.uuidString + ".json")
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func applyPointerRepair(_ plan: PointerRepairPlan) async throws -> PointerRepairBackup {
        let lease = try acquireRawManagementLease(common: plan.common); defer { releaseRelatedManagementLock(lease) }
        guard plan.mainRoot.path == root.path else { throw GitFailure("The selected repository changed.") }
        var record = PointerRepairBackup(id: UUID(), date: Date(), mainPath: root.path, targets: plan.targets, state: "applying", before: plan.before, after: plan.after)
        for file in plan.before { guard try rawManagementFile(URL(fileURLWithPath: file.path)) == file else { throw GitFailure("The pointer preview is stale.") } }
        try savePointerRepair(record)
        do { try commitRepairFiles(before: plan.before, after: plan.after); record.state = "applied"; try savePointerRepair(record) }
        catch { record.diagnostic = error.localizedDescription; try? savePointerRepair(record); throw error }
        return record
    }
    public func pointerRepairBackups() throws -> [PointerRepairBackup] {
        let directory = root.appendingPathComponent(".git/gitpico/pointer-repairs")
        try checkManagementAncestors(directory)
        guard try localAttributes(directory) != nil else { return [] }
        var result: [PointerRepairBackup] = []
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            guard let data = try readLocalIndex(file) else { throw GitFailure("A repair record is missing.") }
            let value = try JSONDecoder().decode(PointerRepairBackup.self, from: data)
            if value.mainPath == root.path { result.append(value) }
        }
        return result.sorted { $0.date > $1.date }
    }
    public func resumePointerRepair(_ saved: PointerRepairBackup, undo: Bool = false) throws {
        let lease = try acquireRawManagementLease(common: root.appendingPathComponent(".git")); defer { releaseRelatedManagementLock(lease) }
        guard try pointerRepairBackups().contains(saved), saved.before.map(\.path) == saved.after.map(\.path) else { throw GitFailure("The repair record changed.") }
        let common = root.appendingPathComponent(".git")
        var ownedRoots = [root.path]
        for target in saved.targets where target.id.hasPrefix("worktree:") {
            let name = String(target.id.dropFirst(9)), admin = common.appendingPathComponent("worktrees/" + name)
            guard worktreePath(admin.path) == target.gitDirectory, !name.contains("/") else { throw GitFailure("Invalid worktree repair identity.") }
            var registered: String?
            if let data = try readLocalIndex(admin.appendingPathComponent("gitdir")), var text = String(data: data, encoding: .utf8) {
                if text.last == "\n" { text.removeLast() }; registered = worktreePath(URL(fileURLWithPath: text).deletingLastPathComponent().path)
            }
            let marker = try readGitPointer(URL(fileURLWithPath: target.workingPath + "/.git"))
            guard registered == target.workingPath || marker?.path == target.gitDirectory else { throw GitFailure("The worktree identity is ambiguous. Scan and review its current location again.") }
            ownedRoots.append(target.workingPath)
        }
        for target in saved.targets {
            guard worktreePath(target.workingPath) == target.workingPath, worktreePath(target.gitDirectory) == target.gitDirectory else { throw GitFailure("A repair target has a non-canonical path.") }
            guard ownedRoots.contains(where: { target.workingPath == $0 || target.workingPath.hasPrefix($0 + "/") }) else { throw GitFailure("A repair target is outside the verified working trees.") }
            guard target.gitDirectory.hasPrefix(common.path + "/") || target.gitDirectory == common.path || target.gitDirectory == target.workingPath + "/.git" else { throw GitFailure("A repair target points to foreign Git storage.") }
        }
        for file in saved.before {
            guard worktreePath(file.path) == file.path else { throw GitFailure("A repair file has a non-canonical path.") }
            let own = file.path.hasPrefix(common.path + "/")
            let marker = saved.targets.contains { file.path == $0.workingPath + "/.git" || file.path == $0.workingPath + "/.gitmodules" || file.path == $0.gitDirectory + "/config" || file.path == $0.gitDirectory + "/index" }
            guard own || marker else { throw GitFailure("Invalid repair metadata scope.") }
        }
        var record = saved; record.state = undo ? "restoring" : "applying"; try savePointerRepair(record)
        do {
            try commitRepairFiles(before: undo ? saved.after : saved.before, after: undo ? saved.before : saved.after, allowPartial: saved.state == "applying" || saved.state == "restoring")
            record.state = undo ? "restored" : "applied"; record.diagnostic = nil; try savePointerRepair(record)
        } catch { record.diagnostic = error.localizedDescription; try? savePointerRepair(record); throw error }
    }
}
