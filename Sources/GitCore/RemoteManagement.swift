import Darwin
import Foundation

extension GitRepository {
    public func remoteConfigurations() async throws -> [RemoteConfiguration] {
        let names = try await GitProcess.run(["remote"], at: root).text.split(separator: "\n").map(String.init)
        var result: [RemoteConfiguration] = []
        for name in names {
            func values(_ field: String) async throws -> [String] {
                try await GitProcess.run(["config", "--null", "--get-all", "remote." + name + "." + field], at: root, allowed: [0, 1]).text.components(separatedBy: "\0").filter { !$0.isEmpty }
            }
            let fetch = try await values("url"), push = try await values("pushurl"), refspecs = try await values("fetch")
            result.append(RemoteConfiguration(name: name, fetchURL: fetch.first ?? "", pushURL: push.first ?? fetch.first ?? "", fetchURLs: fetch, pushURLs: push, refspecs: refspecs))
        }
        return result
    }

    func requireRemote(_ expected: RemoteConfiguration) async throws {
        guard try await remoteConfigurations().first(where: { $0.name == expected.name }) == expected else { throw GitFailure("Remote configuration changed outside this preview. Reopen it before continuing.") }
    }

    func validateRemoteName(_ name: String) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value == 0 }) else { throw GitFailure("Enter a valid remote name.") }
        _ = try await GitProcess.run(["check-ref-format", "refs/remotes/" + name + "/check"], at: root)
    }

    public func addRemote(name: String, fetchURLs: [String], pushURLs: [String] = []) async throws {
        try await validateRemoteName(name)
        guard !(try await remoteConfigurations().contains { $0.name == name }) else { throw GitFailure("A remote with this name already exists.") }
        try validateRemoteURLs(fetchURLs, required: true); try validateRemoteURLs(pushURLs, required: false)
        let section = "remote." + name
        var commands = fetchURLs.map { ["--add", section + ".url", $0] } + pushURLs.map { ["--add", section + ".pushurl", $0] }
        commands.append(["--add", section + ".fetch", "+refs/heads/*:refs/remotes/" + name + "/*"])
        try await editLocalConfiguration(commands, absentRemote: name)
    }

    public func editRemote(_ remote: RemoteConfiguration, fetchURLs: [String], pushURLs: [String]) async throws {
        try await requireRemote(remote)
        try validateRemoteURLs(fetchURLs, required: true); try validateRemoteURLs(pushURLs, required: false)
        let prefix = "remote." + remote.name
        let commands = [["--unset-all", prefix + ".url"], ["--unset-all", prefix + ".pushurl"]]
            + fetchURLs.map { ["--add", prefix + ".url", $0] } + pushURLs.map { ["--add", prefix + ".pushurl", $0] }
        try await editLocalConfiguration(commands, expectedRemote: remote)
    }

    public func renameRemote(_ remote: RemoteConfiguration, to name: String) async throws {
        try await requireIdleManagement(); try await validateRemoteName(name); try await requireRemote(remote)
        _ = try await GitProcess.run(["remote", "rename", "--", remote.name, name], at: root)
    }

    public func removeRemote(_ remote: RemoteConfiguration) async throws {
        try await requireIdleManagement(); try await requireRemote(remote)
        let references = try await references().filter { $0.isRemote && $0.name.hasPrefix(remote.name + "/") && !$0.name.hasSuffix("/HEAD") }
        for ref in references { _ = try await backupReference(fullName: "refs/heads/" + ref.name, hash: ref.hash, title: "Remote branch before removing " + remote.name) }
        // Preserve every local config value, including custom fetch mappings and tracking settings.
        let config = try await localConfigurationEntries()
        let prefix = "remote." + remote.name + "."
        let keys = config.filter { $0.key.hasPrefix(prefix) || ($0.key.hasPrefix("branch.") && $0.key.hasSuffix(".remote") && $0.value == remote.name) }
        let branchPrefixes = keys.filter { $0.key.hasPrefix("branch.") }.map { String($0.key.dropLast("remote".count)) }
        let all = config.filter { entry in keys.contains(entry) || branchPrefixes.contains(where: { entry.key == $0 + "merge" }) }
        let backup = RemovedRemote(id: UUID(), configuration: remote, entries: all, date: Date())
        var removed = try await removedRemotes(); removed.insert(backup, at: 0)
        try await writeManagement(removed, name: "removed-remotes.json")
        _ = try await GitProcess.run(["remote", "remove", "--", remote.name], at: root)
    }

    public func removedRemotes() async throws -> [RemovedRemote] { try await readManagement([RemovedRemote].self, name: "removed-remotes.json") ?? [] }

    public func restoreRemote(_ backup: RemovedRemote) async throws {
        guard try await removedRemotes().contains(where: { $0.id == backup.id && $0.configuration == backup.configuration && $0.entries == backup.entries }), !(try await remoteConfigurations().contains { $0.name == backup.configuration.name }) else { throw GitFailure("The recovery record is unavailable or the remote name is already in use.") }
        let current = try await localConfigurationEntries()
        let entries = backup.entries.filter { entry in !entry.key.hasPrefix("branch.") || !current.contains(where: { $0.key == entry.key }) }
        try await editLocalConfiguration(entries.map { ["--add", $0.key, $0.value] }, absentRemote: backup.configuration.name)
    }

    public func fetchRemote(_ remote: RemoteConfiguration?, prune: Bool = false, tags: Bool = false) async throws {
        if let remote { try await requireRemote(remote) }
        let options = (prune ? ["--prune"] : []) + (tags ? ["--tags"] : [])
        _ = try await GitProcess.run(["fetch"] + options + (remote.map { ["--", $0.name] } ?? ["--all"]), at: root, timeout: 120)
    }

    public func pushPreview(remote: RemoteConfiguration, source: Reference?, destination: String, forceWithLease: Bool = false, setUpstream: Bool = false, pushURL: String? = nil) async throws -> RemotePushPreview {
        try await requireRemote(remote)
        guard destination.hasPrefix("refs/heads/") || destination.hasPrefix("refs/tags/") else { throw GitFailure("Choose a full remote branch or tag name.") }
        _ = try await GitProcess.run(["check-ref-format", destination], at: root)
        if let source {
            guard source.isLocal || source.isTag else { throw GitFailure("Publish a local branch or tag.") }
            try await requireReference(source)
        }
        let urls = try await effectivePushURLs(remote)
        let target = pushURL ?? urls.first ?? ""
        guard urls.contains(target), !target.isEmpty else { throw GitFailure("Choose a configured push URL.") }
        let fetch = try await GitProcess.run(["remote", "get-url", "--", remote.name], at: root).text.trimmingCharacters(in: .newlines)
        if setUpstream {
            guard source?.isLocal == true, destination.hasPrefix("refs/heads/"), fetch == target else { throw GitFailure("Tracking requires a local branch and matching fetch/push URLs. Publish first, then configure tracking separately.") }
        }
        let output = try await GitProcess.run(["ls-remote", "--refs", "--", target, destination], at: root, timeout: 120)
        let hash = output.text.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "\t", maxSplits: 1)
            return fields.count == 2 && fields[1] == destination ? String(fields[0]) : nil
        }.first
        if source == nil && hash == nil { throw GitFailure("That remote reference does not exist.") }
        return RemotePushPreview(remote: remote, source: source, destination: destination, remoteHash: hash, setUpstream: setUpstream, forceWithLease: forceWithLease, pushURL: target)
    }

    public func effectivePushURLs(_ remote: RemoteConfiguration) async throws -> [String] {
        try await requireRemote(remote)
        return try await GitProcess.run(["remote", "get-url", "--push", "--all", "--", remote.name], at: root).text.split(separator: "\n").map(String.init)
    }

    public func executePush(_ preview: RemotePushPreview) async throws {
        try await requireRemote(preview.remote)
        if let source = preview.source { try await requireReference(source) }
        guard try await effectivePushURLs(preview.remote).contains(preview.pushURL) else { throw GitFailure("The push destination changed. Reopen the preview.") }
        if (preview.deletes || preview.forceWithLease), let old = preview.remoteHash {
            let exists = try await GitProcess.run(["cat-file", "-e", old], at: root, allowed: [0, 1, 128])
            if exists.status != 0 { _ = try await GitProcess.run(["fetch", "--no-tags", "--no-write-fetch-head", "--", preview.pushURL, old], at: root, timeout: 120) }
            _ = try await backupReference(fullName: preview.destination, hash: old, title: "Server reference before " + (preview.deletes ? "deletion: " : "force push: ") + preview.remote.name + "/" + preview.destination)
        }
        var args = ["push", "--porcelain"]
        if preview.forceWithLease || preview.deletes { args.append("--force-with-lease=" + preview.destination + ":" + (preview.remoteHash ?? "")) }
        let mapping = (preview.source?.hash ?? "") + ":" + preview.destination
        _ = try await GitProcess.run(args + ["--", preview.pushURL, mapping], at: root, timeout: 120)
        if preview.destination.hasPrefix("refs/heads/") {
            let short = String(preview.destination.dropFirst("refs/heads/".count))
            let tracking = "refs/remotes/" + preview.remote.name + "/" + short
            let fetch = try await GitProcess.run(["remote", "get-url", "--", preview.remote.name], at: root).text.trimmingCharacters(in: .newlines)
            if fetch == preview.pushURL {
                let old = try await GitProcess.run(["show-ref", "--verify", "--hash", "--", tracking], at: root, allowed: [0, 1, 128]).text.trimmingCharacters(in: .newlines)
                if let source = preview.source {
                    _ = try await GitProcess.run(["update-ref", tracking, source.hash, old.isEmpty ? String(repeating: "0", count: source.hash.count) : old], at: root)
                } else if !old.isEmpty { _ = try await GitProcess.run(["update-ref", "-d", tracking, old], at: root) }
            }
            if preview.setUpstream, let source = preview.source {
                try await editLocalConfiguration([["--replace-all", "branch." + source.name + ".remote", preview.remote.name], ["--replace-all", "branch." + source.name + ".merge", preview.destination]])
            }
        }
    }

    private func validateRemoteURLs(_ urls: [String], required: Bool) throws {
        guard !required || !urls.isEmpty, urls.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.contains("\n") && !$0.utf8.contains(0) }) else { throw GitFailure("Enter valid repository URLs, one per line.") }
    }

    private func localConfigurationEntries() async throws -> [ConfigurationEntry] {
        let value = try await GitProcess.run(["config", "--local", "--null", "--list"], at: root).text
        return value.components(separatedBy: "\0").compactMap { record in
            let fields = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return fields.count == 2 ? ConfigurationEntry(key: String(fields[0]), value: String(fields[1])) : nil
        }
    }

    private func editLocalConfiguration(_ commands: [[String]], expectedRemote: RemoteConfiguration? = nil, absentRemote: String? = nil) async throws {
        let path = try await GitProcess.run(["rev-parse", "--path-format=absolute", "--git-path", "config"], at: root).text.trimmingCharacters(in: .newlines)
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw GitFailure("The local Git config must be a regular file.") }
        let original = try Data(contentsOf: url)
        if let expectedRemote { try await requireRemote(expectedRemote) }
        if let absentRemote, try await remoteConfigurations().contains(where: { $0.name == absentRemote }) { throw GitFailure("A remote with this name was added outside GitPico. Reopen the preview.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-config-" + UUID().uuidString)
        try original.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for command in commands { _ = try await GitProcess.run(["config", "--file", temporary.path] + command, at: root, allowed: command.first == "--unset-all" ? [0, 5] : [0]) }
        let lock = path + ".lock"
        let descriptor = Darwin.open(lock, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw GitFailure("The Git config is locked by another operation. Retry after it finishes.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(atPath: lock) }
        guard try Data(contentsOf: url) == original else { throw GitFailure("The Git config changed outside GitPico. Reopen the editor.") }
        try handle.write(contentsOf: Data(contentsOf: temporary)); try handle.synchronize()
        if let mode = attributes[.posixPermissions] as? NSNumber { _ = fchmod(descriptor, mode_t(mode.uint16Value)) }
        guard Darwin.rename(lock, path) == 0 else { throw GitFailure("Could not atomically save the Git config.") }
    }
}

public struct ConfigurationEntry: Codable, Equatable, Sendable { public let key: String; public let value: String }
public struct RemovedRemote: Codable, Identifiable, Sendable {
    public let id: UUID
    public let configuration: RemoteConfiguration
    public let entries: [ConfigurationEntry]
    public let date: Date
}
