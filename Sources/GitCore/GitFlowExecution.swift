import Foundation

extension GitRepository {
    public func activeGitFlow() async throws -> GitFlowRecord? {
        try await readExtensionRecord(GitFlowRecord.self, name: "flow/active.json")
    }
    func saveFlow(_ record: GitFlowRecord) async throws {
        try await writeExtensionRecord(record, name: "flow/history/" + record.id.uuidString + ".json")
        try await writeExtensionRecord(record, name: "flow/active.json")
    }
    func closeFlow(_ record: GitFlowRecord) async throws {
        try await writeExtensionRecord(record, name: "flow/history/" + record.id.uuidString + ".json")
        let url = try await managementURL("flow/active.json")
        if try localAttributes(url) != nil { try FileManager.default.removeItem(at: url) }
    }
    public func gitFlowHistory() async throws -> [GitFlowRecord] {
        let base = try await managementURL("flow/history")
        guard try localAttributes(base) != nil else { return [] }
        var result: [GitFlowRecord] = []
        for file in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), let record = try await readExtensionRecord(GitFlowRecord.self, name: "flow/history/" + id.uuidString + ".json") else { continue }
            result.append(record)
        }
        return result.sorted { $0.date > $1.date }
    }
    @discardableResult public func applyGitFlow(_ plan: GitFlowPlan) async throws -> GitFlowRecord? {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        try await requireFlowIdle()
        guard plan.repository == root.path, try await flowGuard() == plan.before else { throw GitFailure("Branches, configuration, staging or HEAD changed. Review Git Flow again.") }
        switch plan.action {
        case .configure:
            let config = try await commonDirectory().appendingPathComponent("config"), before = try rawManagementFile(config)
            let after = ManagementFile(path: config.path, data: try await editedConfiguration(before.data, values: plan.configuration.values))
            let id = UUID()
            try await writeExtensionRecord(["before": before.data ?? Data(), "after": after.data ?? Data()], name: "flow/configuration/" + id.uuidString + ".json")
            try commitRepairFiles(before: [before], after: [after])
            if plan.before.refs["refs/heads/" + plan.configuration.development] == nil {
                _ = try await GitProcess.run(["update-ref", "refs/heads/" + plan.configuration.development, plan.source, String(repeating: "0", count: plan.source.count)], at: root)
            }
            return nil
        case .start, .track:
            if let remote = plan.remoteRef { guard try await verifiedCommit(remote) == plan.source else { throw GitFailure("The remote tracking branch changed after preview.") } }
            try await protectUntrackedDestinations(plan.source)
            _ = try await GitProcess.run(["checkout", "--no-overwrite-ignore", "--no-track", "-b", plan.branch, plan.source, "--"], at: root)
            if let remote = plan.remoteRef { _ = try await GitProcess.run(["branch", "--set-upstream-to=" + remote, "--", plan.branch], at: root) }
            return nil
        case .finish:
            for target in plan.targets + [plan.branch] { try await requireFlowBranchAvailable(target) }
            var steps: [GitFlowStep] = []
            for (index, target) in plan.targets.enumerated() {
                steps += [GitFlowStep(operation: "checkout", target: target, source: nil), GitFlowStep(operation: "merge", target: target, source: index == 0 ? plan.source : nil)]
                if index == 0, let tag = plan.tag { steps.append(GitFlowStep(operation: "tag", target: tag, source: nil)) }
            }
            if !plan.keepBranch { steps.append(GitFlowStep(operation: "delete", target: plan.branch, source: plan.source)) }
            var record = GitFlowRecord(id: UUID(), date: Date(), repository: root.path, kind: plan.kind, branch: plan.branch, title: plan.kind.finishTitle + " · " + plan.name, tag: plan.tag, message: plan.message, signTag: plan.signTag, state: "ready", next: 0, configuration: plan.configuration, initial: plan.before, expected: plan.before, steps: steps)
            for (index, hash) in Set([plan.source] + plan.targets.compactMap { plan.before.refs["refs/heads/" + $0] }).sorted().enumerated() { try await checkpoint(hash, id: record.id, side: "flow-\(index)") }
            try await saveFlow(record)
            record = try await advanceFlow(record)
            return record
        }
    }
    public func resumeGitFlow(_ saved: GitFlowRecord) async throws -> GitFlowRecord {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        guard saved.repository == root.path, try await activeGitFlow() == saved else { throw GitFailure("Open the owning repository and reload its active Git Flow operation.") }
        return try await advanceFlow(saved)
    }
    func advanceFlow(_ saved: GitFlowRecord) async throws -> GitFlowRecord {
        var record = saved
        guard record.repository == root.path, record.steps.count <= 12, (0...record.steps.count).contains(record.next), !record.steps.isEmpty,
              record.expected.refs.values.allSatisfy({ [40,64].contains($0.count) && $0.allSatisfy(\.isHexDigit) }) else { throw GitFailure("Invalid saved Git Flow state.") }
        try await validateFlowConfiguration(record.configuration)
        for step in record.steps {
            guard ["checkout", "merge", "tag", "delete"].contains(step.operation), [record.configuration.production, record.configuration.development, record.branch, record.tag].compactMap({ $0 }).contains(step.target), step.source.map({ [40,64].contains($0.count) && $0.allSatisfy(\.isHexDigit) }) ?? true else { throw GitFailure("Invalid saved Git Flow step.") }
        }
        do {
            while record.next < record.steps.count {
                let step = record.steps[record.next]
                var current = try await flowGuard()
                guard current.config == record.expected.config else { throw GitFailure("Git configuration changed during this flow. Keep the new settings before continuing.") }
                if record.waiting {
                    let source = try step.source ?? flowHash(record.expected.refs["refs/heads/" + record.configuration.production])
                    let target = "refs/heads/" + step.target
                    guard current.head.branch == target, current.refs.filter({ $0.key != target }) == record.expected.refs.filter({ $0.key != target }) else { throw GitFailure("A branch changed outside the active merge. Existing history was preserved.") }
                    if try await currentOperation() == .merge {
                        guard current.head == record.expected.head else { throw GitFailure("The merge HEAD changed outside Git Flow.") }
                        try await requireFlowMergeOwnership(record)
                        guard try await GitProcess.run(["diff", "--name-only", "--diff-filter=U", "-z"], at: root).data.isEmpty else { throw GitFailure("Resolve and stage merge conflicts, then continue Git Flow.") }
                        _ = try await GitProcess.run(["commit", "--no-edit"], at: root, timeout: 120, acceptGeneratedMessage: true)
                        current = try await flowGuard()
                    }
                    try await requireIdleManagement(); try await requireCleanHistoryWorktree()
                    if current.head != record.expected.head {
                        guard let hash = current.head.hash, let old = record.expected.head.hash,
                              try await GitProcess.run(["merge-base", "--is-ancestor", old, hash], at: root, allowed: [0,1]).status == 0,
                              try await GitProcess.run(["merge-base", "--is-ancestor", source, hash], at: root, allowed: [0,1]).status == 0 else { throw GitFailure("The resolved merge does not contain both reviewed histories.") }
                        record.expected = current; record.next += 1; record.waiting = false; record.state = "ready"; try await saveFlow(record); continue
                    }
                    // A manually aborted or not-yet-started merge can be retried without discarding files.
                    record.waiting = false
                }
                if record.state == "running", try await reconcileFlowStep(&record, step: step, current: current) { continue }
                guard current == record.expected else { throw GitFailure("HEAD, staging or branches changed outside this flow. Existing changes were kept.") }
                try await requireIdleManagement(); try await requireCleanHistoryWorktree()
                try await requireFlowBranchAvailable(step.operation == "tag" ? record.configuration.production : step.target)
                record.state = "running"; record.waiting = step.operation == "merge"; try await saveFlow(record)
                switch step.operation {
                case "checkout":
                    let hash = try flowHash(record.expected.refs["refs/heads/" + step.target])
                    try await protectUntrackedDestinations(hash)
                    _ = try await GitProcess.run(["checkout", "--no-overwrite-ignore", step.target, "--"], at: root)
                case "merge":
                    let source = try step.source ?? flowHash(record.expected.refs["refs/heads/" + record.configuration.production])
                    try await protectUntrackedDestinations(source)
                    _ = try await GitProcess.run(["merge", "--no-ff", "--no-edit", "-m", "Merge branch '" + record.branch + "' into " + step.target, source], at: root, timeout: 120, acceptGeneratedMessage: true)
                case "tag":
                    let message = record.message.isEmpty ? step.target : record.message
                    _ = try await GitProcess.run(["tag", record.signTag ? "-s" : "--no-sign", "-a", "-m", message, "--", step.target, "HEAD"], at: root, timeout: 120)
                case "delete":
                    guard let hash = step.source else { throw GitFailure("The topic backup is unavailable.") }
                    _ = try await GitProcess.run(["update-ref", "-d", "refs/heads/" + step.target, hash], at: root)
                default: throw GitFailure("Unknown Git Flow step.")
                }
                record.expected = try await flowGuard(); record.next += 1; record.waiting = false; record.state = "ready"; record.diagnostic = nil; try await saveFlow(record)
            }
            record.state = "completed"; record.diagnostic = nil; try await closeFlow(record); return record
        } catch {
            record.state = "paused"; record.diagnostic = error.localizedDescription; try? await saveFlow(record)
            throw GitFailure("\(error.localizedDescription)\nGit Flow progress was saved. Resolve the current operation, then use Continue Git Flow; the topic and completed history are retained.")
        }
    }
    func reconcileFlowStep(_ record: inout GitFlowRecord, step: GitFlowStep, current: GitFlowGuard) async throws -> Bool {
        var accepted = false
        switch step.operation {
        case "checkout": accepted = current.refs == record.expected.refs && current.head.branch == "refs/heads/" + step.target && current.head.hash == current.refs[current.head.branch]
        case "delete":
            let ref = "refs/heads/" + step.target
            accepted = current.refs[ref] == nil && current.refs == record.expected.refs.filter { $0.key != ref } && current.head == record.expected.head && current.index == record.expected.index
        case "tag":
            let ref = "refs/tags/" + step.target
            if current.refs[ref] != nil, current.refs.filter({ $0.key != ref }) == record.expected.refs, current.head == record.expected.head {
                let target = try await verifiedCommit(ref)
                let object = try await GitProcess.run(["for-each-ref", "--format=%(objecttype)%00%(contents)", ref], at: root).text.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
                let message = record.message.isEmpty ? step.target : record.message
                let contents = object.count == 2 ? String(object[1]).trimmingCharacters(in: .newlines) : ""
                accepted = target == current.head.hash && object.first == "tag" && (contents == message || contents.hasPrefix(message + "\n"))
            }
        default: break
        }
        if accepted { try await requireIdleManagement(); try await requireCleanHistoryWorktree(); record.expected = current; record.next += 1; record.state = "ready"; try await saveFlow(record) }
        return accepted
    }
    public func stopGitFlow(_ saved: GitFlowRecord) async throws {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        guard saved.repository == root.path, try await activeGitFlow() == saved else { throw GitFailure("The active Git Flow operation changed.") }
        if try await currentOperation() == .merge {
            guard saved.waiting, try await headPosition() == saved.expected.head else { throw GitFailure("The current merge does not belong to this flow.") }
            try await requireFlowMergeOwnership(saved)
            _ = try await GitProcess.run(["merge", "--abort"], at: root)
        } else { try await requireIdleManagement() }
        var record = saved; record.state = "stopped"; record.diagnostic = localized("Earlier completed merges/tags were kept. The topic branch and recovery checkpoints remain available.")
        try await closeFlow(record)
    }
    private func requireFlowMergeOwnership(_ record: GitFlowRecord) async throws {
        guard record.waiting, record.next >= 0, record.next < record.steps.count else { throw GitFailure("There is no reviewed Git Flow merge to continue or abort.") }
        let step = record.steps[record.next]
        guard step.operation == "merge" else { throw GitFailure("The saved step does not own the current merge.") }
        let source = try step.source ?? flowHash(record.expected.refs["refs/heads/" + record.configuration.production])
        let marker = URL(fileURLWithPath: try gitPathOutput(await GitProcess.run(["rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD"], at: root)))
        try checkManagementAncestors(marker)
        guard try readLocalIndex(marker) == Data((source + "\n").utf8) else { throw GitFailure("Another merge replaced the Git Flow merge. Its resolution and files were preserved.") }
    }
}

private func flowHash(_ value: String?) throws -> String { guard let value else { throw GitFailure("A required branch is missing.") }; return value }
