import Foundation
import CryptoKit

struct RepositoryPointer: Codable, Equatable, Sendable {
    let workingPath: String
    let gitDirectory: String
    let gitFile: Bool
    let head: HeadPosition
}
struct ManagementFile: Codable, Equatable, Sendable {
    let path: String
    let data: Data?
    var semantic: Data? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.path == rhs.path else { return false }
        if let left = lhs.semantic, let right = rhs.semantic { return left == right && (lhs.data == nil) == (rhs.data == nil) }
        return lhs.data == rhs.data
    }
}

extension GitRepository {
    func managementFile(_ path: String) async throws -> ManagementFile {
        let path = worktreePath(path), url = URL(fileURLWithPath: worktreePath(path))
        try checkManagementAncestors(url)
        var file = ManagementFile(path: path, data: try readLocalIndex(url))
        if url.lastPathComponent == "index", file.data != nil {
            let entries = try await GitProcess.run(["ls-files", "--stage", "-z"], at: root, indexFile: url).data
            let flags = try await GitProcess.run(["ls-files", "-v", "-z"], at: root, indexFile: url).data
            let debug = try await GitProcess.run(["ls-files", "--debug", "-z"], at: root, indexFile: url).data
            // Include extended flags such as intent-to-add: object/mode/path and -v alone
            // cannot distinguish staging an empty file from its earlier add -N entry.
            // --debug is not a stable porcelain format. An unrecognized format falls back
            // to strict index bytes rather than weakening stale-staging protection.
            var extended = Data(), recognized = true
            if let text = String(data: debug, encoding: .utf8) {
                let blocks = text.components(separatedBy: "\0").dropFirst()
                recognized = blocks.count == entries.split(separator: 0).count
                for block in blocks {
                    let lines = block.split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: false)
                    guard lines.count >= 5, lines[0].hasPrefix("  ctime:"), let separator = lines[4].range(of: "\tflags: ") else { recognized = false; break }
                    let value = lines[4][separator.upperBound...]
                    guard !value.isEmpty, value.allSatisfy(\.isHexDigit) else { recognized = false; break }
                    extended += Data(value.utf8) + Data([0])
                }
            } else { recognized = false }
            file.semantic = recognized ? entries + Data([0]) + flags + Data([0]) + extended : file.data
        }
        return file
    }
    nonisolated func checkManagementAncestors(_ url: URL) throws {
        var current = url
        while current.path != "/" {
            // Darwin's system aliases are outside repository control and must not reject
            // otherwise canonical temporary directories returned by Foundation.
            if ["/var", "/tmp", "/etc"].contains(current.path) { current.deleteLastPathComponent(); continue }
            if let attributes = try localAttributes(current), attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw GitFailure("Management paths cannot traverse symbolic links.") }
            current.deleteLastPathComponent()
        }
    }
    // A bounded, stable content fingerprint. Links are recorded without following their targets.
    func managementDirectoryDigest(_ url: URL, excluding: Set<String> = []) throws -> String? {
        guard let attributes = try localAttributes(url) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw GitFailure("The managed folder was replaced by a file or symbolic link.") }
        try checkManagementAncestors(url)
        var digest = SHA256(), count = 0, bytes: UInt64 = 0
        func feed(_ value: String) { digest.update(data: Data(value.utf8)); digest.update(data: Data([0])) }
        func walk(_ directory: URL, relative: String) throws {
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let relativeName = relative + "/" + child.lastPathComponent
                if excluding.contains(relativeName) { continue }
                count += 1; guard count <= 100_000 else { throw GitFailure("Management backups support up to 100,000 entries.") }
                let attrs = try FileManager.default.attributesOfItem(atPath: child.path), type = attrs[.type] as? FileAttributeType
                let childRelative = relative + "/" + child.lastPathComponent
                feed(childRelative); feed(String((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0))
                if type == .typeDirectory { feed("directory"); try walk(child, relative: childRelative) }
                else if type == .typeSymbolicLink { feed("link"); feed(try FileManager.default.destinationOfSymbolicLink(atPath: child.path)) }
                else if type == .typeRegular {
                    feed("file"); let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                    bytes += size; guard bytes <= 2_147_483_648 else { throw GitFailure("Management backups support up to 2 GB per directory.") }
                    feed(String(size)); let handle = try FileHandle(forReadingFrom: child); defer { try? handle.close() }
                    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
                } else { throw GitFailure("Management backups cannot copy sockets, devices or special files.") }
            }
        }
        try walk(url, relative: ""); return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func repositoryPointers(includeRoot: Bool, depth: Int = 0, allowedStorage: URL? = nil, additionalStorage: [URL] = []) async throws -> [RepositoryPointer] {
        guard depth < 16 else { throw GitFailure("Repository relocation supports up to 16 nested levels.") }
        let storage: URL
        if let allowedStorage { storage = allowedStorage } else { storage = try await commonDirectory() }
        var result: [RepositoryPointer] = [], additionalStorage = additionalStorage
        if includeRoot {
            let admin = URL(fileURLWithPath: try gitPathOutput(await GitProcess.run(["rev-parse", "--absolute-git-dir"], at: root))).resolvingSymlinksInPath()
            let embedded = root.appendingPathComponent(".git").resolvingSymlinksInPath()
            if admin.path == embedded.path { additionalStorage.append(embedded) }
            guard ([storage] + additionalStorage).contains(where: { admin.path.hasPrefix($0.path + "/") || admin.path == $0.path }) else { throw GitFailure("A module's Git storage is outside the verified repository.") }
            try checkManagementAncestors(admin)
            let marker = root.appendingPathComponent(".git"), file = try localAttributes(marker)?[.type] as? FileAttributeType == .typeRegular
            result.append(RepositoryPointer(workingPath: root.path, gitDirectory: admin.path, gitFile: file, head: try await headPosition()))
        }
        for module in try await managedSubmodules() where module.initialized {
            let child = try await checkedSubmodule(module)
            result += try await child.repositoryPointers(includeRoot: true, depth: depth + 1, allowedStorage: storage, additionalStorage: additionalStorage)
            guard result.count <= 512 else { throw GitFailure("Repository relocation supports up to 512 initialized repositories.") }
        }
        return result
    }
    func pointerFiles(_ pointers: [RepositoryPointer]) async throws -> [ManagementFile] {
        var paths = Set<String>()
        for pointer in pointers {
            paths.formUnion([pointer.gitDirectory + "/config", pointer.gitDirectory + "/HEAD", pointer.gitDirectory + "/index"])
            if pointer.gitFile { paths.insert(pointer.workingPath + "/.git") }
        }
        var files: [ManagementFile] = []
        for path in paths.sorted() { files.append(try await managementFile(path)) }; return files
    }
    nonisolated func relocatedPath(_ path: String, from: String, to: String) -> String {
        path == from ? to : path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : path
    }
    func reconnectPointers(_ pointers: [RepositoryPointer], from: String, to: String) async throws {
        for pointer in pointers {
            let working = relocatedPath(pointer.workingPath, from: from, to: to)
            let admin = relocatedPath(pointer.gitDirectory, from: from, to: to)
            try checkManagementAncestors(URL(fileURLWithPath: working)); try checkManagementAncestors(URL(fileURLWithPath: admin))
            _ = try await GitProcess.run(["config", "--file", admin + "/config", "core.worktree", working], at: root)
            if pointer.gitFile {
                try Data(("gitdir: " + admin + "\n").utf8).write(to: URL(fileURLWithPath: working + "/.git"), options: .atomic)
            }
            let child = try await GitRepository.open(URL(fileURLWithPath: working))
            guard child.root.path == working, try await child.headPosition() == pointer.head else { throw GitFailure("A relocated module differs from the reviewed revision. Use Management Backups to restore it.") }
        }
    }
    func moveNestedSubmodule(_ module: ManagedSubmodule, to value: String) async throws {
        let child = try await checkedSubmodule(module)
        let pointers = try await child.repositoryPointers(includeRoot: true, allowedStorage: commonDirectory())
        let destination = try validateLocalPath(value), source = try validateLocalPath(module.path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await GitProcess.run(["--literal-pathspecs", "mv", "--", module.path, value], at: root)
        try await reconnectPointers(pointers, from: source.path, to: destination.path)
        _ = try await GitProcess.run(["add", "--", ".gitmodules"], at: root)
    }
}
