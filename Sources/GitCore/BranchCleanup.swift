import Foundation

public struct BranchCleanupCandidate: Identifiable, Sendable {
    public var id: String { branch.fullName }
    public let branch: Reference
    public let lastCommitDate: Date
    public let reasons: [String]
    public let protection: String?
    public var canArchive: Bool { protection == nil && !reasons.isEmpty }
}

extension GitRepository {
    public func branchCleanupCandidates(base: String, staleDays: Int = 90, now: Date = Date()) async throws -> [BranchCleanupCandidate] {
        let baseHash = try await verifiedCommit(base)
        let refs = try await references(), organization = try await referenceOrganization()
        let local = refs.filter { $0.isLocal && $0.fullName != base && !organization.archived.contains($0.fullName) }
        guard local.count <= 256 else { throw GitFailure("Review branch cleanup in repositories with up to 256 unarchived local branches.") }
        let metadata = try await GitProcess.run(["for-each-ref", "--format=%(refname)%00%(committerdate:unix)%00%(upstream:track)", "refs/heads"], at: root, cancellable: true)
        var dates: [String: Date] = [:], missing: Set<String> = []
        for line in metadata.text.split(separator: "\n") {
            let fields = line.components(separatedBy: "\0")
            guard fields.count == 3 else { continue }
            dates[fields[0]] = Date(timeIntervalSince1970: Double(fields[1]) ?? 0)
            if fields[2] == "[gone]" { missing.insert(fields[0]) }
        }
        var result: [BranchCleanupCandidate] = []
        var basePatchCache: [String: Set<String>] = [:]
        for branch in local {
            try Task.checkCancellation()
            var reasons: [String] = [], protection: String?
            if branch.isCurrent { protection = localized("Checked-out branch") }
            else if organization.pinned.contains(branch.fullName) { protection = localized("Pinned branch") }
            else {
                do { try await requireBranchNotInOtherWorktree(branch, allowCurrent: false) }
                catch { protection = error.localizedDescription }
            }
            let date = dates[branch.fullName] ?? .distantPast
            if missing.contains(branch.fullName) { reasons.append(localized("Tracking branch missing locally")) }
            if now.timeIntervalSince(date) >= Double(max(1, staleDays)) * 86_400 { reasons.append(localized("No commits for \(max(1, staleDays)) days")) }
            let ancestor = try await GitProcess.run(["merge-base", "--is-ancestor", branch.hash, baseHash], at: root, allowed: [0, 1], cancellable: true)
            if ancestor.status == 0 { reasons.insert(localized("Merged into base"), at: 0) }
            else if protection == nil {
                let equivalent = try await GitProcess.run(["cherry", baseHash, branch.hash], at: root, cancellable: true)
                let patches = equivalent.text.split(separator: "\n")
                if !patches.isEmpty && patches.allSatisfy({ $0.hasPrefix("- ") }) {
                    reasons.insert(localized("Equivalent commit patches in base"), at: 0)
                } else {
                    let common = try await GitProcess.run(["merge-base", baseHash, branch.hash], at: root, allowed: [0, 1], cancellable: true)
                    if common.status == 0 {
                        let commonHash = common.text.trimmingCharacters(in: .newlines)
                        let patch = try await GitProcess.run(["diff", "--no-ext-diff", "--no-textconv", "--binary", commonHash, branch.hash, "--"], at: root, cancellable: true)
                        let id = try await cleanupPatchID(patch.data)
                        if !id.isEmpty {
                            if basePatchCache[commonHash] == nil {
                                let history = try await GitProcess.run(["log", "--no-show-signature", "--first-parent", "--max-count=200", "--format=%H", "-p", "--binary", "--no-ext-diff", "--no-textconv", commonHash + ".." + baseHash, "--"], at: root, cancellable: true)
                                let output = try await GitProcess.run(["patch-id", "--stable"], at: root, input: history.data, cancellable: true)
                                let ids = Set(output.text.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
                                basePatchCache[commonHash] = ids
                            }
                            if basePatchCache[commonHash]?.contains(id) == true { reasons.insert(localized("Combined patch found in base history"), at: 0) }
                        }
                    }
                }
            }
            if !reasons.isEmpty {
                result.append(BranchCleanupCandidate(branch: branch, lastCommitDate: date, reasons: reasons, protection: protection))
            }
        }
        return result.sorted { $0.branch.name.localizedStandardCompare($1.branch.name) == .orderedAscending }
    }

    private func cleanupPatchID(_ data: Data) async throws -> String {
        guard !data.isEmpty else { return "" }
        let output = try await GitProcess.run(["patch-id", "--stable"], at: root, input: data, cancellable: true)
        return output.text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    public func archiveCleanupBranches(_ branches: [Reference]) async throws {
        guard !branches.isEmpty, branches.count <= 256, Set(branches.map(\.fullName)).count == branches.count else { throw GitFailure("Choose distinct local branches to archive.") }
        try await requireIdleManagement()
        var organization = try await referenceOrganization()
        // Validate the entire selection before changing any organization metadata.
        for branch in branches {
            guard branch.isLocal, !organization.pinned.contains(branch.fullName) else { throw GitFailure("Pinned branches cannot be archived by cleanup.") }
            try await requireReference(branch)
            try await requireBranchNotInOtherWorktree(branch, allowCurrent: false)
        }
        organization.archived.formUnion(branches.map(\.fullName))
        try await writeManagement(organization, name: "organization.json")
    }
}
