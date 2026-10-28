import Foundation

public struct LFSFileLock: Codable, Sendable, Identifiable, Equatable {
    public struct Owner: Codable, Sendable, Equatable { public let name: String }
    public let id: String
    public let path: String
    public let owner: Owner
    public let locked_at: String?
}
public enum LFSLockAction: Sendable {
    case lock(String), unlock(LFSFileLock, force: Bool)
    public var title: String { switch self { case .lock: localized("Lock File"); case .unlock(_, let force): force ? localized("Force Unlock File") : localized("Unlock File") } }
    public var path: String { switch self { case .lock(let path): path; case .unlock(let lock, _): lock.path } }
}
public struct LFSLockPlan: Sendable {
    public let action: LFSLockAction
    public let remote: String
    let repository: String
    let head: HeadPosition
    let guards: [ManagementFile]
}
extension GitRepository {
    public func lfsLocks(remote: String, id: String? = nil) async throws -> [LFSFileLock] {
        try await requireLFS()
        guard try await remoteConfigurations().contains(where: { $0.name == remote }), !remote.hasPrefix("-"), !remote.contains("\n") else { throw GitFailure("Choose a configured remote.") }
        struct Locks: Decodable { let locks: [LFSFileLock] }
        let options = id.map { ["--id=" + $0] } ?? ["--limit=1000"]
        let output = try await GitProcess.run(["lfs", "locks", "--json", "--remote=" + remote] + options, at: root, timeout: 120)
        let decoder = JSONDecoder()
        let locks: [LFSFileLock]
        if let list = try? decoder.decode([LFSFileLock].self, from: output.data) { locks = list }
        else { locks = try decoder.decode(Locks.self, from: output.data).locks }
        guard locks.count <= 1000 else { throw GitFailure("The lock list exceeds 1000 entries. Narrow it using your server's tools.") }
        return locks
    }
    public func previewLFSLock(_ action: LFSLockAction, remote: String) async throws -> LFSLockPlan {
        try await requireLFS(); try await requireIdleManagement()
        _ = try validateLocalPath(action.path)
        guard try await remoteConfigurations().contains(where: { $0.name == remote }) else { throw GitFailure("Choose a configured remote.") }
        if case .lock(let path) = action {
            guard FileManager.default.fileExists(atPath: try validateLocalPath(path).path) else { throw GitFailure("Locking requires a file in the working copy.") }
        }
        return LFSLockPlan(action: action, remote: remote, repository: root.path, head: try await headPosition(), guards: try await lfsTransferGuards())
    }
    public func runLFSLock(_ plan: LFSLockPlan) async throws {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        guard plan.repository == root.path, try await headPosition() == plan.head, try await lfsTransferGuards() == plan.guards else { throw GitFailure("Repository, HEAD, index or LFS configuration changed. Review the lock operation again.") }
        try await requireIdleManagement()
        let arguments: [String]
        switch plan.action {
        case .lock(let path): arguments = ["lock", "--json", "--remote=" + plan.remote, "--", path]
        case .unlock(let reviewed, let force):
            guard try await lfsLocks(remote: plan.remote, id: reviewed.id).contains(reviewed) else { throw GitFailure("The lock changed or was removed. Reload server locks.") }
            arguments = ["unlock", "--json", "--remote=" + plan.remote, "--id=" + reviewed.id] + (force ? ["--force"] : [])
        }
        _ = try await GitProcess.run(["lfs"] + arguments, at: root, timeout: 120)
    }
}
