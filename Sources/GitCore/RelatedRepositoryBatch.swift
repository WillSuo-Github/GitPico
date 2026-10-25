import Foundation
import Darwin

public enum WorktreeBatchOperation: String, CaseIterable, Codable, Sendable {
    case lock = "Lock", unlock = "Unlock", move = "Move", remove = "Remove", forceRemove = "Force Remove (Keep Backup)", forceUnlockRemove = "Unlock and Force Remove (Keep Backup)", prune = "Prune Missing Registrations"
}
public struct RelatedBatchItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var worktree: ManagedWorktree?
    public var submodule: ManagedSubmodule?
    public let operation: String
    public let value: String
    public var state: String = "pending"
    public var diagnostic: String?
    public var path: String { worktree?.path ?? submodule?.path ?? "" }
}
public struct RelatedBatchReport: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let repository: String
    public let title: String
    public let recursive: Bool
    public let localTransport: Bool
    public var items: [RelatedBatchItem]
    public var state: String = "prepared"
    public var diagnostic: String?
}
struct BatchParentState: Equatable, Sendable { let head: HeadPosition; let index: Data?; let modules: Data?; let config: Data?; let worktrees: [ManagedWorktree] }
public struct RelatedBatchPlan: Sendable {
    public let report: RelatedBatchReport
    let parent: BatchParentState
    let previous: RelatedBatchReport?
}

extension GitRepository {
    func batchParentState() async throws -> BatchParentState {
        BatchParentState(head: try await headPosition(), index: try await submoduleAddIndex(), modules: try submoduleConfigurationData(), config: try readLocalIndex(try await commonDirectory().appendingPathComponent("config")), worktrees: try await managedWorktrees())
    }
    func saveRelatedBatch(_ report: RelatedBatchReport) async throws {
        let file = try await managementURL("related-batches/" + report.id.uuidString + ".json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(report).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func relatedBatchReports() async throws -> [RelatedBatchReport] {
        let directory = try await managementURL("related-batches")
        guard try localAttributes(directory) != nil else { return [] }
        var reports: [RelatedBatchReport] = []
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), let value = try await readManagement(RelatedBatchReport.self, name: "related-batches/" + id.uuidString + ".json"), value.repository == root.path else { continue }
            reports.append(value)
        }
        return reports.sorted { $0.date > $1.date }
    }
    public func previewWorktreeBatch(_ targets: [ManagedWorktree], operation: WorktreeBatchOperation, value: String = "") async throws -> RelatedBatchPlan {
        try await requireIdleManagement()
        guard !targets.isEmpty, targets.count <= 128, Set(targets.map(\.id)).count == targets.count else { throw GitFailure("Choose 1–128 distinct worktrees.") }
        var items: [RelatedBatchItem] = [], destinations = Set<String>()
        for target in targets {
            try await requireWorktree(target)
            guard !target.isMain, !target.isBare else { throw GitFailure("Select linked worktrees only.") }
            var destination = value
            let forced = operation == .forceRemove || operation == .forceUnlockRemove
            if operation == .move || operation == .remove || forced || operation == .prune {
                guard target.path != root.path, target.locked == nil || operation == .forceUnlockRemove else { throw GitFailure("Deselect the current or locked worktree.") }
                if operation == .prune, try localAttributes(URL(fileURLWithPath: target.path)) != nil { throw GitFailure("Prune only targets missing directories. Deselect the available worktree.") }
                if target.prunable == nil && !forced {
                    let child = try await checkedWorktree(target); try await requireCleanTreeForManagement(child)
                    for module in try await child.managedSubmodules() { try await child.requireModuleTreeClean(module, recursive: true, requireRecorded: operation == .remove) }
                } else if operation == .move { throw GitFailure("Repair a missing worktree before moving it.") }
            }
            if operation == .move {
                guard value.hasPrefix("/") else { throw GitFailure("Choose an absolute destination parent folder.") }
                destination = try await newWorktreeDestination(URL(fileURLWithPath: value).appendingPathComponent(target.name)).path
                guard destinations.insert(destination).inserted else { throw GitFailure("Selected worktrees have colliding destination names.") }
            }
            if operation == .lock, target.locked != nil { throw GitFailure("A selected worktree is already locked.") }
            if operation == .unlock, target.locked == nil { throw GitFailure("A selected worktree is not locked.") }
            items.append(RelatedBatchItem(id: UUID(), worktree: target, operation: operation.rawValue, value: destination))
        }
        return RelatedBatchPlan(report: RelatedBatchReport(id: UUID(), date: Date(), repository: root.path, title: operation.rawValue + " Worktrees", recursive: true, localTransport: false, items: items), parent: try await batchParentState(), previous: nil)
    }
    public func previewSubmoduleBatch(_ targets: [ManagedSubmodule], operation: SubmoduleOperation, value: String = "", recursive: Bool = true, allowLocalTransport: Bool = false) async throws -> RelatedBatchPlan {
        guard !targets.isEmpty, targets.count <= 128, Set(targets.map(\.id)).count == targets.count else { throw GitFailure("Choose 1–128 distinct submodules.") }
        var items: [RelatedBatchItem] = [], destinations = Set<String>()
        for target in targets {
            let destination = operation == .move ? (value.isEmpty ? URL(fileURLWithPath: target.path).lastPathComponent : value + "/" + URL(fileURLWithPath: target.path).lastPathComponent) : value
            let plan = try await previewSubmodule(target, operation: operation, value: destination, recursive: recursive, allowLocalTransport: allowLocalTransport)
            if operation == .move, !destinations.insert(plan.value).inserted { throw GitFailure("Selected modules have colliding destination names.") }
            items.append(RelatedBatchItem(id: UUID(), submodule: target, operation: operation.rawValue, value: plan.value))
        }
        return RelatedBatchPlan(report: RelatedBatchReport(id: UUID(), date: Date(), repository: root.path, title: operation.rawValue + " · Submodules", recursive: recursive, localTransport: allowLocalTransport, items: items), parent: try await batchParentState(), previous: nil)
    }
    func currentBatchModule(_ expected: ManagedSubmodule) async throws -> ManagedSubmodule {
        guard let current = try await managedSubmodules().first(where: { $0.id == expected.id }) else { throw GitFailure("A selected submodule disappeared.") }
        let adjusted = ManagedSubmodule(name: expected.name, path: expected.path, url: expected.url, configuredURL: expected.configuredURL, branch: expected.branch, recordedHash: expected.recordedHash, head: expected.head, gitDirectory: expected.gitDirectory, initialized: expected.initialized, dirty: expected.dirty, conflicted: expected.conflicted, diagnostic: expected.diagnostic, configuration: current.configuration)
        guard adjusted == current else { throw GitFailure("A selected submodule changed outside the reviewed batch.") }
        return current
    }
    public func previewResumeRelatedBatch(_ report: RelatedBatchReport) async throws -> RelatedBatchPlan {
        guard let stored = try await relatedBatchReports().first(where: { $0.id == report.id }), stored == report, stored.state != "completed" else { throw GitFailure("The batch changed or has already completed.") }
        var refreshed = stored
        for index in refreshed.items.indices where refreshed.items[index].state != "completed" {
            let item = refreshed.items[index]
            if let worktree = item.worktree {
                guard let current = try await managedWorktrees().first(where: { $0.id == worktree.id }), let operation = WorktreeBatchOperation(rawValue: item.operation) else { throw GitFailure("The target moved or disappeared. Restore its management backup before retrying.") }
                let parent = operation == .move ? URL(fileURLWithPath: item.value).deletingLastPathComponent().path : item.value
                _ = try await previewWorktreeBatch([current], operation: operation, value: parent)
                refreshed.items[index].worktree = current
            } else if let module = item.submodule {
                guard let current = try await managedSubmodules().first(where: { $0.id == module.id }), let operation = SubmoduleOperation(rawValue: item.operation) else { throw GitFailure("The module disappeared. Restore its backup before retrying.") }
                _ = try await previewSubmodule(current, operation: operation, value: item.value, recursive: report.recursive, allowLocalTransport: report.localTransport)
                refreshed.items[index].submodule = current
            }
            refreshed.items[index].state = "pending"; refreshed.items[index].diagnostic = nil
        }
        refreshed.state = "prepared"; refreshed.diagnostic = nil
        return RelatedBatchPlan(report: refreshed, parent: try await batchParentState(), previous: stored)
    }
    public func applyRelatedBatch(_ plan: RelatedBatchPlan, progress: (@Sendable (RelatedBatchReport) async -> Void)? = nil) async throws -> RelatedBatchReport {
        let lockFile = try await managementURL("related-batches/" + plan.report.id.uuidString + ".lease")
        try FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw GitFailure("Unable to open the batch lease.") }
        defer { Darwin.close(descriptor) }
        let flockFunction: (Int32, Int32) -> Int32 = flock
        guard flockFunction(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw GitFailure("This batch is already running in another session.") }
        guard plan.report.repository == root.path, try await batchParentState() == plan.parent else { throw GitFailure("The repository changed after the batch preview. Review it again.") }
        if let previous = plan.previous { guard try await relatedBatchReports().first(where: { $0.id == previous.id }) == previous else { throw GitFailure("The saved batch changed.") } }
        var report = plan.report, expected = plan.parent
        report.state = "running"; try await saveRelatedBatch(report)
        for index in report.items.indices where report.items[index].state != "completed" {
            if Task.isCancelled { report.state = "paused"; break }
            let item = report.items[index]
            do {
                guard try await batchParentState() == expected else { throw GitFailure("The parent repository changed between batch items.") }
                report.items[index].state = "running"; try await saveRelatedBatch(report); await progress?(report)
                if let target = item.worktree, let operation = WorktreeBatchOperation(rawValue: item.operation) {
                    switch operation {
                    case .lock: try await setWorktreeLocked(target, locked: true, reason: item.value)
                    case .unlock: try await setWorktreeLocked(target, locked: false)
                    case .move: try await moveWorktree(target, to: URL(fileURLWithPath: item.value))
                    case .remove: try await removeWorktree(target)
                    case .forceRemove: try await removeWorktree(target, force: true)
                    case .forceUnlockRemove: try await removeWorktree(target, force: true, unlock: true)
                    case .prune: try await removeWorktree(target, missingOnly: true)
                    }
                } else if let target = item.submodule, let operation = SubmoduleOperation(rawValue: item.operation) {
                    let current = try await currentBatchModule(target)
                    let operationPlan = try await previewSubmodule(current, operation: operation, value: item.value, recursive: report.recursive, allowLocalTransport: report.localTransport)
                    try await applySubmodule(operationPlan)
                } else { throw GitFailure("Invalid batch item.") }
                report.items[index].state = "completed"; expected = try await batchParentState()
                try await saveRelatedBatch(report); await progress?(report)
            } catch {
                report.items[index].state = "failed"; report.items[index].diagnostic = error.localizedDescription
                report.state = "stopped"; report.diagnostic = "Stopped after \(report.items.filter { $0.state == "completed" }.count) completed item(s). " + error.localizedDescription
                try await saveRelatedBatch(report); await progress?(report); return report
            }
        }
        if report.state == "running" { report.state = "completed" }
        try await saveRelatedBatch(report); await progress?(report); return report
    }
}
