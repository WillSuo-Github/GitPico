import Foundation

extension GitRepository {
    public func setReferenceOrganization(_ references: [Reference], archived: Bool? = nil, pinned: Bool? = nil) async throws {
        try await requireReferenceBatch(references, localOnly: true)
        var value = try await referenceOrganization()
        for ref in references {
            if let archived { if archived { value.archived.insert(ref.fullName) } else { value.archived.remove(ref.fullName) } }
            if let pinned { if pinned { value.pinned.insert(ref.fullName) } else { value.pinned.remove(ref.fullName) } }
        }
        try await writeManagement(value, name: "organization.json")
    }

    public func deleteReferences(_ references: [Reference], force: Bool = false) async throws {
        try await requireIdleManagement()
        try await requireReferenceBatch(references, localOnly: false)
        let head = try await headPosition()
        // Preflight the entire selection before creating backups or deleting any reference.
        for ref in references where ref.isLocal {
            try await requireBranchNotInOtherWorktree(ref, allowCurrent: false)
            if !force {
                guard let hash = head.hash else { throw GitFailure("Choose a committed HEAD before deleting branches.") }
                let result = try await GitProcess.run(["merge-base", "--is-ancestor", ref.hash, hash], at: root, allowed: [0, 1])
                guard result.status == 0 else { throw GitFailure("This branch has commits not merged into HEAD. Review them or explicitly allow deletion of an unmerged branch.") }
            }
        }
        for ref in references {
            _ = try await backupReference(fullName: ref.fullName, hash: ref.hash,
                                          title: ref.isTag ? localized("Deleted tag \(ref.name)") : localized("Deleted branch \(ref.name)"))
        }
        // Old object IDs make a concurrent reference change reject the whole transaction.
        let commands = "start\n" + references.map { "delete \($0.fullName) \($0.hash)\n" }.joined() + "prepare\ncommit\n"
        _ = try await GitProcess.run(["update-ref", "--stdin"], at: root, input: Data(commands.utf8))
        var organization = try await referenceOrganization()
        for ref in references where ref.isLocal {
            _ = try await GitProcess.run(["config", "--local", "--remove-section", "branch." + ref.name], at: root, allowed: [0, 128, 5])
            organization.pinned.remove(ref.fullName); organization.archived.remove(ref.fullName)
        }
        try await writeManagement(organization, name: "organization.json")
    }

    private func requireReferenceBatch(_ references: [Reference], localOnly: Bool) async throws {
        guard !references.isEmpty, references.count <= 256, Set(references.map(\.fullName)).count == references.count,
              references.allSatisfy({ $0.isLocal || (!localOnly && $0.isTag) }) else {
            throw GitFailure("Choose up to 256 distinct local branches or tags.")
        }
        for ref in references { try await requireReference(ref) }
    }
}
