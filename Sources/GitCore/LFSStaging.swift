import Foundation
import CryptoKit

struct LFSInput: Equatable, Sendable { let path: String; let digest: String; let mode: Int }
public struct LFSStagingPlan: Sendable {
    public let paths: [String]
    public let summary: String
    let repository: String
    let head: HeadPosition
    let before: ManagementFile
    let after: ManagementFile
    let inputs: [LFSInput]
    let attributes: Data
    let filters: Data
}
extension GitRepository {
    func lfsInput(_ path: String) throws -> LFSInput {
        let url = try validateLocalPath(path)
        guard let attributes = try localAttributes(url), attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max) <= 2 * 1024 * 1024 * 1024 else { throw GitFailure("LFS conversion supports existing regular files up to 2 GB each.") }
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        var hash = SHA256(), bytes = 0
        while let block = try reader.read(upToCount: 1024 * 1024), !block.isEmpty {
            bytes += block.count
            guard bytes <= 2 * 1024 * 1024 * 1024 else { throw GitFailure("An LFS input grew beyond 2 GB while being inspected.") }
            hash.update(data: block)
        }
        return LFSInput(path: path, digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), mode: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0)
    }
    func lfsAttributes(_ paths: [String]) async throws -> Data {
        try await GitProcess.run(["check-attr", "-z", "--all", "--stdin"], at: root, input: Data((paths.joined(separator: "\0") + "\0").utf8)).data
    }
    func lfsFilterConfiguration() async throws -> Data {
        try await GitProcess.run(["config", "--null", "--get-regexp", "^filter\\.lfs\\."], at: root, allowed: [0,1]).data
    }
    public func previewLFSStaging(paths selection: [String] = []) async throws -> LFSStagingPlan {
        try await requireIdleManagement(); try await requireLFS()
        let shared = try await GitProcess.run(["rev-parse", "--shared-index-path"], at: root).text.trimmingCharacters(in: .newlines)
        let sparse = try await GitProcess.run(["config", "--bool", "core.sparseCheckout"], at: root, allowed: [0,1]).text.trimmingCharacters(in: .newlines)
        guard shared.isEmpty, sparse != "true" else { throw GitFailure("Disable split-index and expand sparse checkout before using recoverable LFS conversion.") }
        let tracked = try await GitProcess.run(["ls-files", "-z"], at: root).data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard tracked.count <= 50_000 else { throw GitFailure("Select explicit files in repositories with more than 50,000 tracked paths.") }
        let candidates = selection.isEmpty ? Array(Set(tracked)).sorted() : Array(Set(selection)).sorted()
        guard candidates.allSatisfy({ tracked.contains($0) }) else { throw GitFailure("Choose tracked files for conversion; new files are converted by normal staging after enabling a pattern.") }
        let attributeData = try await lfsAttributes(candidates), fields = attributeData.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var matching = Set<String>()
        guard fields.count % 3 == 0 else { throw GitFailure("Invalid Git attribute records.") }
        for index in stride(from: 0, to: fields.count, by: 3) where fields[index + 1] == "filter" && fields[index + 2] == "lfs" { matching.insert(fields[index]) }
        let paths = candidates.filter { matching.contains($0) }
        guard !paths.isEmpty, paths.count <= 128, selection.isEmpty || paths.count == candidates.count else { throw GitFailure("Choose 1–128 tracked files matching an LFS pattern. Use file context menus to narrow the selection.") }
        guard try await GitProcess.run(["ls-files", "--unmerged", "-z"], at: root).data.isEmpty else { throw GitFailure("Resolve staging conflicts before converting files to LFS.") }
        let stage = try await GitProcess.run(["ls-files", "--stage", "-z", "--"] + paths, at: root).data.split(separator: 0)
        guard stage.allSatisfy({ $0.starts(with: Data("100".utf8)) }) else { throw GitFailure("LFS conversion does not stage symbolic links or submodules.") }
        let flags = try await GitProcess.run(["ls-files", "-v", "-z", "--"] + paths, at: root).data.split(separator: 0)
        guard flags.allSatisfy({ $0.first == UInt8(ascii: "H") }) else { throw GitFailure("Clear assume-unchanged and skip-worktree flags before LFS conversion.") }
        let before = try rawManagementFile(try await localIndexURL()), head = try await headPosition(), inputs = try paths.map(lfsInput)
        let attributes = try await lfsAttributes(paths), filters = try await lfsFilterConfiguration()
        let scratch = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let index = try await scratchIndex(before.data, in: scratch)
        _ = try await GitProcess.run(["add", "--renormalize", "--"] + paths, at: root, timeout: 120, indexFile: index)
        struct Converted: Decodable { let files: [LFSFile]? }
        let converted = try JSONDecoder().decode(Converted.self, from: await GitProcess.run(["lfs", "ls-files", "--json"], at: root, indexFile: index).data).files ?? []
        guard Set(paths).isSubset(of: Set(converted.map(\.name))) else { throw GitFailure("The selected files were not converted to LFS pointers. Enable working LFS filters first.") }
        let summary = try await GitProcess.run(["diff", "--cached", "--stat", "--"] + paths, at: root, indexFile: index).text
        guard try paths.map(lfsInput) == inputs, try await lfsAttributes(paths) == attributes, try await lfsFilterConfiguration() == filters, try rawManagementFile(URL(fileURLWithPath: before.path)) == before else { throw GitFailure("Files, attributes, filters or staging changed while preparing LFS conversion.") }
        return LFSStagingPlan(paths: paths, summary: summary, repository: root.path, head: head, before: before, after: ManagementFile(path: before.path, data: try Data(contentsOf: index)), inputs: inputs, attributes: attributes, filters: filters)
    }
    public func applyLFSStaging(_ plan: LFSStagingPlan) async throws {
        let lease = try await acquireRelatedManagementLock(); defer { releaseRelatedManagementLock(lease) }
        try await requireIdleManagement()
        guard plan.repository == root.path, try await headPosition() == plan.head, try plan.paths.map(lfsInput) == plan.inputs, try await lfsAttributes(plan.paths) == plan.attributes, try await lfsFilterConfiguration() == plan.filters else { throw GitFailure("LFS conversion inputs changed. Review the files again.") }
        var record = LFSChangeRecord(id: UUID(), date: Date(), title: localized("Stage LFS Conversion · \(plan.paths.count) file(s)"), repository: root.path, head: plan.head, state: "applying", before: [plan.before], after: [plan.after])
        try await pinManagementIndex(plan.before.data, id: record.id, side: "lfs-before")
        try await pinManagementIndex(plan.after.data, id: record.id, side: "lfs-after")
        try await writeExtensionRecord(record, name: "lfs/changes/" + record.id.uuidString + ".json")
        try commitRepairFiles(before: [plan.before], after: [plan.after])
        record.state = "applied"; try await writeExtensionRecord(record, name: "lfs/changes/" + record.id.uuidString + ".json")
    }
}
