import Foundation

public struct HistoricalFile: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let object: String
    public let mode: String
    public let data: Data
    public var isRegular: Bool { mode == "100644" || mode == "100755" }
    public var isLink: Bool { mode == "120000" }
    public var isSubmodule: Bool { mode == "160000" }
}

public struct HistoricalSnapshot: Sendable {
    public let revision: String
    public let date: Date
    public let files: [HistoricalFile]
    public var totalBytes: Int { files.reduce(0) { $0 + $1.data.count } }
    public var warnings: [String] {
        files.contains(where: \.isSubmodule) ? ["Submodules are exported as empty directories; their separate repositories are not included."] : []
    }
}

public enum HistoricalRestoreTarget: String, CaseIterable, Sendable {
    case workingCopy, both
    public var title: String { self == .workingCopy ? "Working Copy Only" : "Working Copy and Index" }
}

extension GitRepository {
    public func historicalSnapshot(revision: String, paths: [String] = []) async throws -> HistoricalSnapshot {
        for path in paths { try validateInspectionPath(path); try HistoricalExport.validatePath(path) }
        let hash = try await verifiedCommit(revision)
        let commit = try await commit(at: hash)
        let output = try await GitProcess.run(["ls-tree", "-r", "-l", "-z", "--full-tree", hash, "--"] + paths, at: root)
        var entries: [(path: String, object: String, mode: String, size: Int)] = []
        var total = 0
        for field in output.data.split(separator: 0) {
            guard let tab = field.firstIndex(of: 9), let path = String(data: field[(tab + 1)...], encoding: .utf8) else { throw GitFailure("Historical export requires UTF-8 filenames.") }
            try HistoricalExport.validatePath(path)
            let header = String(decoding: field[..<tab], as: UTF8.self).split(whereSeparator: \.isWhitespace)
            guard header.count == 4, ["100644", "100755", "120000", "160000"].contains(String(header[0])) else { throw GitFailure("Unsupported historical tree entry: " + path) }
            let size = header[0] == "160000" ? 0 : Int(header[3]) ?? Int.max
            guard size <= 16 * 1024 * 1024, total <= 64 * 1024 * 1024 - size, entries.count < 10_000 else { throw GitFailure("Export supports 10,000 entries, 16 MB per file and 64 MB total. Select a smaller folder.") }
            total += size; entries.append((path, String(header[2]), String(header[0]), size))
        }
        guard paths.allSatisfy({ selected in entries.contains { $0.path == selected || $0.path.hasPrefix(selected + "/") } }) else { throw GitFailure("A selected file or directory does not exist at this revision. For a deletion, select its previous revision.") }
        let names = entries.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(names).count == names.count else { throw GitFailure("Export cannot represent case-aliasing filenames safely on this Mac.") }
        let blobs = entries.filter { $0.mode != "160000" }
        let input = Data(blobs.map { $0.object + "\n" }.joined().utf8)
        let outputData = try await GitProcess.run(["cat-file", "--batch"], at: root, input: input, maxOutputBytes: 66 * 1024 * 1024).data
        var cursor = 0, files: [HistoricalFile] = [], contents: [String: Data] = [:]
        for entry in blobs {
            guard cursor < outputData.count, let newline = outputData[cursor...].firstIndex(of: 10) else { throw GitFailure("Incomplete historical object output.") }
            let header = String(decoding: outputData[cursor..<newline], as: UTF8.self).split(separator: " ")
            guard header.count == 3, header[0] == entry.object, header[1] == "blob", Int(header[2]) == entry.size,
                  newline + 1 + entry.size < outputData.count, outputData[newline + 1 + entry.size] == 10 else { throw GitFailure("Historical object data did not match its tree entry.") }
            contents[entry.path] = Data(outputData[(newline + 1)..<(newline + 1 + entry.size)])
            cursor = newline + entry.size + 2
        }
        guard cursor == outputData.count else { throw GitFailure("Unexpected historical object output.") }
        for entry in entries { files.append(HistoricalFile(path: entry.path, object: entry.object, mode: entry.mode, data: contents[entry.path] ?? Data())) }
        return HistoricalSnapshot(revision: hash, date: commit.date, files: files)
    }

    public func previewHistoricalRestore(_ snapshot: HistoricalSnapshot, destination: String? = nil, target: HistoricalRestoreTarget = .workingCopy) async throws -> LocalChangePlan {
        guard !snapshot.files.isEmpty, snapshot.files.allSatisfy(\.isRegular), snapshot.files.count <= 512 else { throw GitFailure("Restore supports up to 512 regular files. Links and submodules cannot be restored here.") }
        guard destination == nil || snapshot.files.count == 1 else { throw GitFailure("Choose a destination path only for a single-file restore.") }
        let paths = snapshot.files.map { destination ?? $0.path }
        try await requireLocalChangeSupport(paths)
        let head = try await headPosition(), index = try readLocalIndex(try await localIndexURL()), before = try localFiles(paths)
        let tracked = try await GitProcess.run(["ls-files", "-z", "--"] + paths, at: root).text.components(separatedBy: "\0")
        for file in before where file.data != nil && !tracked.contains(file.path) { throw GitFailure("Restore would replace an untracked or ignored file at \(file.path). Choose a new path or move it aside first.") }
        let directory = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: directory) }
        let temporaryIndex = try await scratchIndex(index, in: directory)
        var after: [LocalFileState] = []
        for (file, path) in zip(snapshot.files, paths) {
            // Resolve the exact object again; the source ref may have moved meanwhile.
            let object = try await GitProcess.run(["cat-file", "blob", file.object], at: root).data
            guard object == file.data else { throw GitFailure("The historical source object changed or is unavailable.") }
            let content = try await GitProcess.run(["cat-file", "--filters", "--path=" + path, file.object], at: root).data
            let permissions = ((before.first { $0.path == path }?.permissions ?? 0o644) & ~0o111) | (file.mode == "100755" ? 0o111 : 0)
            after.append(LocalFileState(path: path, data: content, permissions: permissions))
        }
        if target == .both {
            let entries = zip(snapshot.files, paths).map { file, path in "\(file.mode) \(file.object) 0\t\(path)\0" }.joined()
            _ = try await GitProcess.run(["update-index", "-z", "--index-info"], at: root, input: Data(entries.utf8), indexFile: temporaryIndex)
        }
        let afterIndex = target == .both ? try readLocalIndex(temporaryIndex) : index
        try validateLocalStates(before, after)
        guard before != after || index != afterIndex else { throw GitFailure("The selected files already match this revision in the chosen scope.") }
        let summary = zip(snapshot.files, paths).map { "\($0.path) → \($1)  [\($0.mode), \($0.data.count) bytes]" }.joined(separator: "\n")
        return LocalChangePlan(id: UUID(), title: "Restore Historical Files", paths: paths, preview: "Revision: \(snapshot.revision)\n\n" + summary,
                               repository: root.path, head: head, beforeIndex: index, afterIndex: afterIndex, before: before, after: after)
    }
}
