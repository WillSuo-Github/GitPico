import Foundation

public struct ExternalToolCommand: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public init(executable: String, arguments: [String]) { self.executable = executable; self.arguments = arguments }
    public func invocation(files: [String: URL], merge: Bool) throws -> [String] {
        guard executable.hasPrefix("/"), !executable.utf8.contains(0), arguments.count <= 64, !arguments.isEmpty else { throw GitFailure("Choose an absolute tool executable and an argument list.") }
        let required = merge ? ["{local}", "{remote}", "{merged}"] : ["{local}", "{remote}"]
        guard required.allSatisfy({ token in arguments.contains { $0.contains(token) } }) else { throw GitFailure("Tool arguments require {local}, {remote}, and for merging {merged}.") }
        return try arguments.map { argument in
            guard argument.utf8.count <= 8192, !argument.utf8.contains(0) else { throw GitFailure("Invalid tool argument.") }
            var value = "", remainder = argument[...]
            while let first = remainder.first {
                if first == "{" {
                    guard let end = remainder.firstIndex(of: "}"), let url = files[String(remainder[remainder.index(after: remainder.startIndex)..<end])] else { throw GitFailure("Unknown external tool placeholder.") }
                    value += url.path; remainder = remainder[remainder.index(after: end)...]
                } else {
                    guard first != "}" else { throw GitFailure("Unknown external tool placeholder.") }
                    value.append(first); remainder.removeFirst()
                }
            }
            return value
        }
    }
}

public struct ExternalToolSession: Codable, Sendable, Identifiable {
    public let id: UUID
    public let path: String
    public let title: String
    public let date: Date
    public let repository: String
    public let head: HeadPosition
    public let conflict: ConflictSnapshot?
    public internal(set) var applied: Bool
    public var isMerge: Bool { conflict != nil }
}

extension GitRepository {
    func externalDirectory(_ id: UUID) async throws -> URL { try await gitPicoURL("external-tools/" + id.uuidString) }
    func saveExternalSession(_ session: ExternalToolSession) async throws {
        let directory = try await externalDirectory(session.id)
        let file = directory.appendingPathComponent("session.json")
        _ = try await gitPicoURL("external-tools/\(session.id.uuidString)/session.json")
        try JSONEncoder().encode(session).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func externalSession(_ id: UUID) async throws -> ExternalToolSession {
        guard let value = try await loadRecovery(ExternalToolSession.self, name: "external-tools/\(id.uuidString)/session.json"), value.id == id, value.repository == root.path else { throw GitFailure("External tool session is missing or belongs to another working tree.") }
        try validateInspectionPath(value.path)
        guard value.conflict == nil || value.conflict?.path == value.path else { throw GitFailure("Invalid external conflict session.") }
        return value
    }
    public func externalSessions() async throws -> [ExternalToolSession] {
        let directory = try await gitPicoURL("external-tools")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var result: [ExternalToolSession] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            if let record = try? await externalSession(id) { result.append(record) }
        }
        return result.sorted { $0.date > $1.date }
    }
    public func externalFiles(_ session: ExternalToolSession) async throws -> [String: URL] {
        let stored = try await externalSession(session.id)
        let baseName = (stored.path as NSString).lastPathComponent
        let name = baseName.utf8.count <= 200 ? baseName : "file.bin"
        var result: [String: URL] = [:]
        for side in ["local", "remote", "base", "merged"] {
            let url = try await gitPicoURL("external-tools/\(stored.id.uuidString)/\(side)/\(name)")
            guard let attributes = try localAttributes(url), attributes[.type] as? FileAttributeType == .typeRegular else { throw GitFailure("A tool session input or output is missing or is not a regular file.") }
            result[side] = url
        }
        return result
    }
    func makeExternalSession(path: String, title: String, head: HeadPosition, local: Data, remote: Data, base: Data = Data(), merged: Data = Data(), conflict: ConflictSnapshot? = nil) async throws -> ExternalToolSession {
        try validateInspectionPath(path)
        let session = ExternalToolSession(id: UUID(), path: path, title: title, date: Date(), repository: root.path, head: head, conflict: conflict, applied: false)
        let directory = try await externalDirectory(session.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let baseName = (path as NSString).lastPathComponent, name = baseName.utf8.count <= 200 ? baseName : "file.bin"
        do {
            for (side, data) in [("local", local), ("remote", remote), ("base", base), ("merged", merged)] {
                guard data.count <= 16 * 1024 * 1024 else { throw GitFailure("External tool files are limited to 16 MB each.") }
                let folder = directory.appendingPathComponent(side)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = folder.appendingPathComponent(name)
                try data.write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: side == "merged" ? 0o600 : 0o400], ofItemAtPath: file.path)
            }
            try await saveExternalSession(session)
            return session
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    public func prepareExternalDiff(path: String, staged: Bool = false) async throws -> ExternalToolSession {
        try validateInspectionPath(path); _ = try validateLocalPath(path)
        let head = try await headPosition()
        let entries = try await workingFiles()
        guard let entry = entries.first(where: { $0.path == path }), entry.change?.isConflicted != true else { throw GitFailure("Select a tracked/untracked non-conflicted file for comparison.") }
        func blob(_ spec: String) async throws -> Data? {
            let type = try await GitProcess.run(["cat-file", "-t", spec], at: root, allowed: [0, 128])
            guard type.status == 0 else { return nil }
            guard type.text == "blob\n" else { throw GitFailure("External comparison supports files, not trees or submodules.") }
            return try await GitProcess.run(["cat-file", "blob", spec], at: root).data
        }
        let modes = try await GitProcess.run(["ls-files", "--stage", "-z", "--", path], at: root).text
        guard !modes.hasPrefix("120000 "), !modes.hasPrefix("160000 ") else { throw GitFailure("Compare regular files rather than symbolic links or submodules.") }
        let index = try await blob(":" + path)
        let local: Data, remote: Data
        if staged {
            if let hash = head.hash { local = try await blob(hash + ":" + (entry.change?.originalPath ?? path)) ?? Data() } else { local = Data() }
            remote = index ?? Data()
        } else {
            local = index == nil ? Data() : try await GitProcess.run(["cat-file", "--filters", "--path=" + path, ":" + path], at: root).data
            remote = try localFiles([path]).first?.data ?? Data()
        }
        return try await makeExternalSession(path: path, title: staged ? "HEAD ↔ Index" : "Index ↔ Working Copy", head: head, local: local, remote: remote)
    }
    public func prepareExternalComparison(left: String?, right: String, path: String, originalPath: String? = nil) async throws -> ExternalToolSession {
        let lhs: String?
        if let left { lhs = try await verifiedCommit(left) } else { lhs = nil }
        let rhs = try await verifiedCommit(right)
        for path in [path, originalPath].compactMap({ $0 }) { try validateInspectionPath(path) }
        func contents(_ hash: String, _ path: String) async throws -> Data? {
            let result = try await GitProcess.run(["cat-file", "-e", hash + ":" + path], at: root, allowed: [0, 128])
            return result.status == 0 ? try await GitProcess.run(["cat-file", "blob", hash + ":" + path], at: root).data : nil
        }
        let local: Data?
        if let lhs {
            let source: String
            if let originalPath { source = originalPath }
            else { source = try await compareRevisions(left: lhs, right: rhs).originalPaths[path] ?? path }
            local = try await contents(lhs, source)
        } else { local = nil }
        let remote = try await contents(rhs, path)
        guard local != nil || remote != nil else { throw GitFailure("This file does not exist in either compared revision.") }
        return try await makeExternalSession(path: path, title: (lhs.map { String($0.prefix(8)) } ?? "Empty") + " ↔ " + rhs.prefix(8), head: headPosition(), local: local ?? Data(), remote: remote ?? Data())
    }

    public func prepareExternalMerge(path: String) async throws -> ExternalToolSession {
        let head = try await headPosition(), snapshot = try await conflict(path)
        guard snapshot.canEdit, let local = snapshot.version(2), let remote = snapshot.version(3) else { throw GitFailure("External merge currently requires regular UTF-8 current/incoming files. Use the whole-file controls for binary or deletion conflicts.") }
        return try await makeExternalSession(path: path, title: "Resolve Conflict", head: head, local: local.data, remote: remote.data, base: snapshot.version(1)?.data ?? Data(), merged: snapshot.workingData ?? Data(), conflict: snapshot)
    }
    public func applyExternalMerge(_ id: UUID, expectedResult: Data? = nil) async throws {
        var session = try await externalSession(id)
        guard !session.applied, let original = session.conflict, try await headPosition() == session.head, try await currentOperation() == original.operation else { throw GitFailure("The session was applied or HEAD/operation changed. Reopen the conflict.") }
        let fresh = try await conflict(original.path)
        guard fresh.permissions == original.permissions, fresh.indexSignature == original.indexSignature, fresh.workingData == original.workingData else { throw GitFailure("The conflict file or index changed. Reopen the merge session.") }
        let files = try await externalFiles(session)
        guard let output = files["merged"], let attributes = try localAttributes(output), (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576 else { throw GitFailure("Merge output must be a regular UTF-8 file under 1 MB.") }
        let data = try Data(contentsOf: output)
        guard expectedResult == nil || data == expectedResult else { throw GitFailure("The tool saved a newer result. Reload and review it before applying.") }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8), !ConflictDocument(text).hasMarkers else { throw GitFailure("Save a complete UTF-8 result without conflict markers before applying.") }
        try await resolveConflict(original, resolution: .edited(text))
        session.applied = true; try await saveExternalSession(session)
    }
    public func deleteExternalSession(_ id: UUID) async throws {
        _ = try await externalSession(id)
        let directory = try await externalDirectory(id)
        try FileManager.default.removeItem(at: directory)
    }
}

