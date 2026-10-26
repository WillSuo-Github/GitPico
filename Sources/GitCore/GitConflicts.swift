import Foundation
import Darwin

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
    public var workingKind: String? = nil
    public var text: String? {
        let data = workingData ?? Data()
        return data.count <= 1_048_576 && !data.contains(0) ? String(data: data, encoding: .utf8) : nil
    }
    public var canEdit: Bool { workingKind != FileAttributeType.typeSymbolicLink.rawValue && workingKind != FileAttributeType.typeDirectory.rawValue && text != nil && versions.allSatisfy { $0.isRegular && $0.text != nil } }
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
            let data = fields[0] == "160000" ? Data(("Submodule commit " + object).utf8) : try await GitProcess.run(["cat-file", "blob", object], at: root).data
            versions.append(ConflictVersion(stage: stage, mode: String(fields[0]), object: object, data: data))
        }
        let url = try conflictURL(path)
        let working = try conflictData(url, directoryAllowed: versions.contains { $0.mode == "160000" })
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? (versions.first { $0.stage == 2 }?.mode == "100755" ? 0o755 : 0o644)
        return ConflictSnapshot(path: path, versions: versions, workingData: working, permissions: permissions, indexSignature: signature, operation: try await currentOperation(), workingKind: (try localAttributes(url)?[.type] as? FileAttributeType)?.rawValue)
    }

    public func resolveConflict(_ snapshot: ConflictSnapshot, resolution: ConflictResolution) async throws {
        let url = try conflictURL(snapshot.path)
        let actualKind = (try localAttributes(url)?[.type] as? FileAttributeType)?.rawValue
        guard try await unmerged(snapshot.path) == snapshot.indexSignature, try conflictData(url, directoryAllowed: snapshot.versions.contains { $0.mode == "160000" }) == snapshot.workingData,
              snapshot.workingKind == nil || snapshot.workingKind == actualKind, try await currentOperation() == snapshot.operation else {
            throw GitFailure("The conflict file or index changed outside this editor. Reload it before saving.")
        }
        if !snapshot.versions.allSatisfy(\.isRegular) {
            guard case .version(let stage) = resolution, [2, 3].contains(stage) else { throw GitFailure("Choose a complete version for a symbolic link or submodule conflict.") }
            try await resolveStructuralConflict(snapshot, stage: stage, url: url)
            return
        }
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
            try writeLocalFile(LocalFileState(path: snapshot.path, data: data, permissions: permissions))
        } else if try localAttributes(url) != nil { try FileManager.default.removeItem(at: url) }
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
        let components = path.split(separator: "/")
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component))
            if index < components.count - 1, let attributes = try? FileManager.default.attributesOfItem(atPath: current.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw GitFailure("Resolve symbolic-link conflicts in an external Git tool.")
            }
        }
        return url
    }

    private func conflictData(_ url: URL, directoryAllowed: Bool = false) throws -> Data? {
        guard let attributes = try localAttributes(url) else { return nil }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8) }
        if directoryAllowed, attributes[.type] as? FileAttributeType == .typeDirectory { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 16 * 1024 * 1024 else {
            throw GitFailure("The conflict editor supports regular files up to 16 MB.")
        }
        return try Data(contentsOf: url)
    }

    private func resolveStructuralConflict(_ snapshot: ConflictSnapshot, stage: Int, url: URL) async throws {
        let chosen = snapshot.version(stage)
        guard chosen == nil || ["100644", "100755", "120000", "160000"].contains(chosen!.mode) else { throw GitFailure("Unsupported Git conflict mode.") }
        let indexURL = try await localIndexURL(), before = try readLocalIndex(try await localIndexURL())
        let scratch = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let index = try await scratchIndex(before, in: scratch)
        let zero = String(repeating: "0", count: chosen?.object.count ?? snapshot.versions[0].object.count)
        var records = "0 \(zero)\t\(snapshot.path)\0"
        if let chosen { records += "\(chosen.mode) \(chosen.object)\t\(snapshot.path)\0" }
        _ = try await GitProcess.run(["update-index", "-z", "--index-info"], at: root, input: Data(records.utf8), indexFile: index)
        let after = try requireIndexData(index)
        let lock = URL(fileURLWithPath: indexURL.path + ".lock")
        let descriptor = Darwin.open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw GitFailure("Git's index is locked. Wait for the other operation and reload the conflict.") }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: lock) }
        let currentKind = (try localAttributes(url)?[.type] as? FileAttributeType)?.rawValue
        guard try readLocalIndex(indexURL) == before, try await unmerged(snapshot.path) == snapshot.indexSignature,
              try conflictData(url, directoryAllowed: true) == snapshot.workingData,
              snapshot.workingKind == nil || snapshot.workingKind == currentKind else { throw GitFailure("The conflict changed. Reload it before choosing a version.") }
        // Gitlinks are index pointers: accepting them never checks out or deletes nested user files.
        if chosen?.mode != "160000", !snapshot.versions.contains(where: { $0.mode == "160000" }) {
            let type = try localAttributes(url)?[.type] as? FileAttributeType
            guard type == nil || type == .typeRegular || type == .typeSymbolicLink else { throw GitFailure("A directory occupies the conflict path. Move it aside before accepting a file.") }
            if let chosen, chosen.mode == "120000" {
                guard let target = String(data: chosen.data, encoding: .utf8), !target.isEmpty, !target.utf8.contains(0), target.utf8.count <= 4096 else { throw GitFailure("The symbolic-link target is invalid.") }
                let temporary = url.deletingLastPathComponent().appendingPathComponent(".gitpico-link-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: target)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard Darwin.rename(temporary.path, url.path) == 0 else { throw GitFailure("Unable to install the selected symbolic link.") }
            } else if let chosen {
                if type == .typeSymbolicLink { try FileManager.default.removeItem(at: url) }
                try chosen.data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: chosen.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: url.path)
            } else if type != nil { try FileManager.default.removeItem(at: url) }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: after); try handle.synchronize()
        guard Darwin.rename(lock.path, indexURL.path) == 0 else { throw GitFailure("Unable to stage the selected version. The chosen working content was retained.") }
    }

    private func requireIndexData(_ url: URL) throws -> Data {
        guard let data = try readLocalIndex(url) else { throw GitFailure("The prepared conflict index is missing.") }
        return data
    }
}
