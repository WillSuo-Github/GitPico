import Foundation

extension GitRepository {
    func lfsTransferGuards() async throws -> [ManagementFile] {
        let paths = [try await commonDirectory().appendingPathComponent("config"), root.appendingPathComponent(".lfsconfig"), try await localIndexURL()]
        return try paths.map { try rawManagementFile($0) }
    }
    public func previewLFSTransfer(_ operation: LFSTransfer, remote: String = "origin", revision: String = "HEAD", allObjects: Bool = false) async throws -> LFSTransferPlan {
        try await requireLFS(); try await requireIdleManagement()
        let hash = try await verifiedCommit(revision), state = try await lfsState()
        guard state.enabled else { throw GitFailure("Enable LFS for this repository before transferring objects.") }
        if operation == .pull { guard hash == (try await headPosition().hash) else { throw GitFailure("Pull checks out the current HEAD. Use Fetch to cache objects from another revision.") } }
        guard !allObjects || operation == .fetch || operation == .push else { throw GitFailure("All-history transfer is available for Fetch and Push only.") }
        if operation != .checkout {
            guard try await remoteConfigurations().contains(where: { $0.name == remote }), !remote.hasPrefix("-"), !remote.contains("\n") else { throw GitFailure("Choose a configured remote.") }
        }
        struct Files: Decodable { let files: [LFSFile]? }
        let files: [LFSFile]
        if operation == .checkout || operation == .pull { files = state.files }
        else { files = try JSONDecoder().decode(Files.self, from: await GitProcess.run(["lfs", "ls-files", "--json", hash], at: root).data).files ?? [] }
        guard files.count <= 50_000 else { throw GitFailure("This LFS revision exceeds the 50,000-file overview limit.") }
        for file in files { _ = try validateLocalPath(file.name) }
        let env = try await GitProcess.run(["lfs", "env"], at: root).text
        let endpoint = env.split(separator: "\n").filter { $0.hasPrefix("Endpoint") || $0.hasPrefix("LocalMediaDir") }.joined(separator: "\n")
        return LFSTransferPlan(operation: operation, remote: remote, hash: hash, paths: files.map(\.name), endpoint: endpoint, allObjects: allObjects, repository: root.path, head: try await headPosition(), guards: try await lfsTransferGuards())
    }
    func requireLFSTransfer(_ plan: LFSTransferPlan) async throws {
        guard plan.repository == root.path, try await headPosition() == plan.head, try await lfsTransferGuards() == plan.guards else { throw GitFailure("The repository, index or LFS endpoint changed after preview.") }
        try await requireIdleManagement()
        for path in plan.paths { _ = try validateLocalPath(path) }
    }
    public func runLFSTransfer(_ plan: LFSTransferPlan, progress: (@Sendable (String) async -> Void)? = nil) async throws -> LFSTransferReport {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        try await requireLFSTransfer(plan)
        let id = UUID(), progressURL = try await managementURL("lfs/progress/" + id.uuidString + ".txt")
        try checkManagementAncestors(progressURL)
        try FileManager.default.createDirectory(at: progressURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: progressURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        let poll = Task {
            var previous = ""
            while !Task.isCancelled {
                if let reader = try? FileHandle(forReadingFrom: progressURL) {
                    let size = (try? reader.seekToEnd()) ?? 0
                    try? reader.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
                    let text = String(decoding: (try? reader.readToEnd()) ?? Data(), as: UTF8.self)
                    try? reader.close()
                    if text != previous { previous = text; await progress?(text) }
                }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
            }
        }
        defer { poll.cancel() }
        let env = ["GIT_LFS_PROGRESS": progressURL.path, "GIT_LFS_FORCE_PROGRESS": "1"]
        var output = ""
        do {
            if plan.operation != .checkout {
                let command = plan.operation == .push ? "push" : "fetch"
                await progress?(command == "push" ? "Uploading LFS objects…" : "Downloading LFS objects…")
                let result = try await GitProcess.run(["lfs", command] + (plan.allObjects ? ["--all"] : []) + [plan.remote, plan.hash], at: root, timeout: 600, lfsEnvironment: env)
                output += result.text + result.error
            }
            if plan.operation == .checkout || plan.operation == .pull {
                // Fetching immutable objects must not turn into checkout on an externally switched branch.
                try await requireLFSTransfer(plan)
                await progress?("Checking out cached LFS objects; modified working files are kept…")
                let result = try await GitProcess.run(["lfs", "checkout"], at: root, timeout: 600, lfsEnvironment: env)
                output += result.text + result.error
            }
            let report = LFSTransferReport(id: id, date: Date(), operation: plan.operation.rawValue, remote: plan.remote, hash: plan.hash, output: output, succeeded: true)
            try await writeExtensionRecord(report, name: "lfs/transfers/" + id.uuidString + ".json")
            poll.cancel(); await poll.value
            await progress?(output.isEmpty ? "Completed." : output)
            return report
        } catch {
            let report = LFSTransferReport(id: id, date: Date(), operation: plan.operation.rawValue, remote: plan.remote, hash: plan.hash, output: output + error.localizedDescription, succeeded: false)
            try? await writeExtensionRecord(report, name: "lfs/transfers/" + id.uuidString + ".json")
            throw error
        }
    }
    public func lfsTransferHistory() async throws -> [LFSTransferReport] {
        let base = try await managementURL("lfs/transfers")
        guard try localAttributes(base) != nil else { return [] }
        var reports: [LFSTransferReport] = []
        for file in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), let report = try await readExtensionRecord(LFSTransferReport.self, name: "lfs/transfers/" + id.uuidString + ".json") else { continue }
            reports.append(report)
        }
        return reports.sorted { $0.date > $1.date }
    }
}
