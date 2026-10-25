import Foundation

extension GitRepository {
    public func lfsState() async throws -> LFSState {
        let version = try await GitProcess.run(["lfs", "version"], at: root, allowed: [0, 1, 128])
        guard version.status == 0 else { return LFSState(available: false, version: "Git LFS is not installed. Install git-lfs and reload.", enabled: false, hookInstalled: false, rules: [], files: [], status: version.error) }
        let filter = try await GitProcess.run(["config", "--get", "filter.lfs.process"], at: root, allowed: [0, 1])
        struct Rules: Decodable { let patterns: [LFSRule]? }
        struct Files: Decodable { let files: [LFSFile]? }
        let rules = try JSONDecoder().decode(Rules.self, from: await GitProcess.run(["lfs", "track", "--json"], at: root).data).patterns ?? []
        let files = try JSONDecoder().decode(Files.self, from: await GitProcess.run(["lfs", "ls-files", "--json"], at: root).data).files ?? []
        guard rules.count <= 10_000, files.count <= 50_000 else { throw GitFailure("The LFS overview exceeds its 10,000-rule / 50,000-file limit.") }
        let hook = try await lfsHookURL(), bytes = try? readLocalIndex(hook)
        return LFSState(available: true, version: version.text.trimmingCharacters(in: .newlines), enabled: filter.status == 0 && !filter.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hookInstalled: bytes.map { String(decoding: $0, as: UTF8.self).contains("lfs pre-push") } ?? false, rules: rules, files: files, status: try await GitProcess.run(["lfs", "status"], at: root).text)
    }
    func requireLFS() async throws {
        guard try await GitProcess.run(["lfs", "version"], at: root, allowed: [0, 1, 128]).status == 0 else { throw GitFailure("Git LFS is not installed. Install git-lfs, then reload this view.") }
    }
    func lfsHookURL() async throws -> URL {
        let setting = try await GitProcess.run(["config", "--get", "core.hooksPath"], at: root, allowed: [0,1])
        let base: URL
        if setting.status == 0 {
            let path = try gitPathOutput(setting)
            base = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        } else { base = try await commonDirectory().appendingPathComponent("hooks") }
        // core.hooksPath may intentionally be /dev/null. Merely inspecting LFS must
        // not attempt to stat a child of a non-directory; writes validate the full path.
        return base.resolvingSymlinksInPath().appendingPathComponent("pre-push")
    }
    static let lfsFilters = ["filter.lfs.clean": "git-lfs clean -- %f", "filter.lfs.smudge": "git-lfs smudge -- %f", "filter.lfs.process": "git-lfs filter-process", "filter.lfs.required": "true"]
    public func previewLFSChange(_ change: LFSChange) async throws -> LFSChangePlan {
        try await requireIdleManagement(); try await requireLFS()
        var before: [ManagementFile] = [], after: [ManagementFile] = [], title = "", preview = ""
        switch change {
        case .enable, .disable:
            let installHook: Bool
            if case .enable(let value) = change { installHook = value } else { installHook = false }
            let config = try await commonDirectory().appendingPathComponent("config"), original = try rawManagementFile(config)
            before.append(original)
            if case .enable = change {
                after.append(ManagementFile(path: config.path, data: try await editedConfiguration(original.data, values: Self.lfsFilters)))
                title = "Enable Git LFS for This Repository"
                if installHook {
                    let hook = try await lfsHookURL(), common = try await commonDirectory()
                    guard hook.path.hasPrefix(common.path + "/hooks/") else { throw GitFailure("The configured hooks directory is external. Enable filters only, then integrate git lfs pre-push into your existing hook manually.") }
                    let originalHook = try rawManagementFile(hook)
                    let scratch = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: scratch) }
                    _ = try await GitProcess.run(["init", "--bare", scratch.path], at: root)
                    _ = try await GitProcess.run(["-c", "core.hooksPath=" + scratch.appendingPathComponent("hooks").path, "lfs", "install", "--local"], at: scratch)
                    let generated = try Data(contentsOf: scratch.appendingPathComponent("hooks/pre-push"))
                    guard originalHook.data == nil || originalHook.data == generated else { throw GitFailure("A custom pre-push hook already exists. Enable filters only to preserve it.") }
                    before.append(originalHook); after.append(ManagementFile(path: hook.path, data: generated))
                }
            } else {
                title = "Disable Git LFS Locally"
                // Local empty overrides prevent inherited filters from silently remaining active.
                after.append(ManagementFile(path: config.path, data: try await editedConfiguration(original.data, values: ["filter.lfs.clean":"", "filter.lfs.smudge":"", "filter.lfs.process":"", "filter.lfs.required":"false"])))
            }
            preview = "Changes repository-local filter configuration. Existing history, .gitattributes and cached objects are preserved. Disabling filters does not convert pointer files or remove a pre-push hook."
        case .track(let pattern, _, let source), .untrack(let pattern, let source):
            let filename: Bool
            if case .track(_, let value, _) = change { filename = value } else { filename = false }
            guard !pattern.isEmpty, !pattern.hasPrefix("-"), !pattern.contains("\n"), !pattern.contains("\r"), !pattern.utf8.contains(0), pattern.utf8.count <= 4096 else { throw GitFailure("Enter one non-empty LFS pattern without line breaks or a leading option.") }
            let target = try validateLocalPath(source)
            guard target.lastPathComponent == ".gitattributes" else { throw GitFailure("Choose a repository .gitattributes file.") }
            let original = try rawManagementFile(target)
            let scratch = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: scratch) }
            let attributes = scratch.appendingPathComponent(source)
            try FileManager.default.createDirectory(at: attributes.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try await GitProcess.run(["init", "-q", scratch.path], at: root)
            if let data = original.data { try data.write(to: attributes) }
            var args = ["-C", attributes.deletingLastPathComponent().path, "lfs"]
            if case .track = change { args += ["track"] + (filename ? ["--filename"] : []) } else { args += ["untrack"] }
            _ = try await GitProcess.run(args + ["--", pattern], at: scratch)
            before.append(original); after.append(ManagementFile(path: target.path, data: try readLocalIndex(attributes)))
            title = (args.contains("untrack") ? "Stop LFS Tracking · " : "Track with LFS · ") + pattern
            preview = String(decoding: after[0].data ?? Data(), as: UTF8.self)
        }
        return LFSChangePlan(title: title, paths: before.map(\.path), preview: preview, repository: root.path, head: try await headPosition(), before: before, after: after)
    }
    public func applyLFSChange(_ plan: LFSChangePlan) async throws {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        guard plan.repository == root.path, try await headPosition() == plan.head else { throw GitFailure("The repository changed. Review LFS settings again.") }
        var record = LFSChangeRecord(id: UUID(), date: Date(), title: plan.title, repository: root.path, head: plan.head, state: "applying", before: plan.before, after: plan.after)
        try await writeExtensionRecord(record, name: "lfs/changes/" + record.id.uuidString + ".json")
        for file in plan.after where file.path.contains("/hooks/") { try FileManager.default.createDirectory(at: URL(fileURLWithPath: file.path).deletingLastPathComponent(), withIntermediateDirectories: true) }
        try commitRepairFiles(before: plan.before, after: plan.after)
        for file in plan.after where file.path.hasSuffix("/hooks/pre-push") { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        record.state = "applied"; try await writeExtensionRecord(record, name: "lfs/changes/" + record.id.uuidString + ".json")
    }
    public func lfsChangeHistory() async throws -> [LFSChangeRecord] {
        let base = try await managementURL("lfs/changes")
        guard try localAttributes(base) != nil else { return [] }
        var records: [LFSChangeRecord] = []
        for entry in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) where entry.pathExtension == "json" {
            guard let id = UUID(uuidString: entry.deletingPathExtension().lastPathComponent), let record = try await readExtensionRecord(LFSChangeRecord.self, name: "lfs/changes/" + id.uuidString + ".json"), record.repository == root.path else { continue }
            records.append(record)
        }
        return records.sorted { $0.date > $1.date }
    }
    public func restoreLFSChange(_ record: LFSChangeRecord) async throws {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        guard try await lfsChangeHistory().contains(record), record.state != "restored", try await headPosition() == record.head else { throw GitFailure("The LFS record or repository changed.") }
        let config = try await commonDirectory().appendingPathComponent("config").path, hook = try await lfsHookURL().path, index = try await localIndexURL().path
        let allowed = Set([config, hook, index].map(worktreePath)), workingRoot = worktreePath(root.path)
        for file in record.before {
            let path = URL(fileURLWithPath: file.path)
            guard file.path == worktreePath(file.path), allowed.contains(file.path) || (file.path.hasPrefix(workingRoot + "/") && path.lastPathComponent == ".gitattributes") else { throw GitFailure("Invalid LFS recovery path.") }
        }
        var restored = record; restored.state = "restoring"
        try await writeExtensionRecord(restored, name: "lfs/changes/" + record.id.uuidString + ".json")
        try commitRepairFiles(before: record.after, after: record.before, allowPartial: record.state == "applying" || record.state == "restoring")
        restored.state = "restored"; try await writeExtensionRecord(restored, name: "lfs/changes/" + record.id.uuidString + ".json")
    }
}
