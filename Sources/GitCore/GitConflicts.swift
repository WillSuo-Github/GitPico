import Foundation

public struct ConflictVersion: Identifiable, Sendable, Codable {
    public var id: Int { stage }
    public let stage: Int
    public let mode: String
    public let object: String
    public let data: Data
    public var text: String? { data.count <= 1_048_576 && !data.contains(0) ? String(data: data, encoding: .utf8) : nil }
    public var isRegular: Bool { mode == "100644" || mode == "100755" }
}

public struct ConflictSnapshot: Sendable, Codable {
    public let path: String
    public let versions: [ConflictVersion]
    public let workingData: Data?
    public let permissions: Int
    public let indexSignature: Data
    public let operation: RepositoryOperation
    public var text: String? {
        let data = workingData ?? Data()
        return data.count <= 1_048_576 && !data.contains(0) ? String(data: data, encoding: .utf8) : nil
    }
    public var canEdit: Bool { text != nil && versions.allSatisfy { $0.isRegular && $0.text != nil } }
    public func version(_ stage: Int) -> ConflictVersion? { versions.first { $0.stage == stage } }
}

public enum ConflictResolution: Sendable { case edited(String), version(Int) }

extension GitRepository {
    public func conflict(_ path: String) async throws -> ConflictSnapshot {
        let signature = try await unmerged(path)
        guard !signature.isEmpty else { throw GitFailure("This file no longer has an unresolved conflict. Refresh the working copy.") }
        var versions: [ConflictVersion] = []
        for record in signature.split(separator: 0) {
            guard let tab = record.firstIndex(of: 9) else { throw GitFailure("Invalid unmerged index entry.") }
            let fields = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            guard fields.count == 3, let stage = Int(fields[2]) else { throw GitFailure("Invalid conflict stage.") }
            let object = String(fields[1])
            let data = try await GitProcess.run(["cat-file", "blob", object], at: root).data
            versions.append(ConflictVersion(stage: stage, mode: String(fields[0]), object: object, data: data))
        }
        let url = try conflictURL(path)
        let working = try conflictData(url)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? (versions.first { $0.stage == 2 }?.mode == "100755" ? 0o755 : 0o644)
        return ConflictSnapshot(path: path, versions: versions, workingData: working, permissions: permissions, indexSignature: signature, operation: try await currentOperation())
    }

    public func resolveConflict(_ snapshot: ConflictSnapshot, resolution: ConflictResolution) async throws {
        let url = try conflictURL(snapshot.path)
        guard try await unmerged(snapshot.path) == snapshot.indexSignature, try conflictData(url) == snapshot.workingData else {
            throw GitFailure("The conflict file or index changed outside this editor. Reload it before saving.")
        }
        guard snapshot.versions.allSatisfy(\.isRegular) else { throw GitFailure("Resolve symlinks and submodules in an external Git tool.") }
        let data: Data?; let permissions: Int
        switch resolution {
        case .edited(let text):
            guard snapshot.canEdit else { throw GitFailure("This conflict cannot be edited as UTF-8 text.") }
            guard !ConflictDocument(text).hasMarkers else { throw GitFailure("Remove every conflict marker before marking this file resolved.") }
            guard !text.utf8.contains(0), text.utf8.count <= 1_048_576 else { throw GitFailure("The resolution must be UTF-8 text under 1 MB without NUL bytes.") }
            data = Data(text.utf8); permissions = snapshot.permissions
        case .version(let stage):
            guard stage == 2 || stage == 3 else { throw GitFailure("Choose the current or incoming version.") }
            let version = snapshot.version(stage)
            data = version?.data; permissions = version?.mode == "100755" ? 0o755 : 0o644
            if let text = version?.text, ConflictDocument(text).hasMarkers { throw GitFailure("This version still contains conflict markers. Edit the result before staging it.") }
        }
        if let data {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        // A hook/filter failure leaves the edited result on disk for recovery.
        _ = try await GitProcess.run(["add", "--all", "--", snapshot.path], at: root)
    }

    private func unmerged(_ path: String) async throws -> Data {
        try await GitProcess.run(["ls-files", "--unmerged", "-z", "--", path], at: root).data
    }

    private func conflictURL(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/"), !path.hasPrefix("/") else { throw GitFailure("Invalid conflict path.") }
        var current = root
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw GitFailure("Resolve symbolic-link conflicts in an external Git tool.")
            }
        }
        return url
    }

    private func conflictData(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 16 * 1024 * 1024 else {
            throw GitFailure("The conflict editor supports regular files up to 16 MB.")
        }
        return try Data(contentsOf: url)
    }
}
