import Foundation
import GitCore

struct CommitFileTreeEntry: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let change: ChangedPath?
    let stats: FileStatistics?

    var isChanged: Bool { change != nil }

    static func == (lhs: CommitFileTreeEntry, rhs: CommitFileTreeEntry) -> Bool {
        lhs.path == rhs.path
            && lhs.change == rhs.change
            && lhs.stats?.additions == rhs.stats?.additions
            && lhs.stats?.deletions == rhs.stats?.deletions
            && lhs.stats?.isBinary == rhs.stats?.isBinary
    }
}

struct CommitFileTreeFolder: Equatable, Sendable {
    let path: String
    let name: String
    let fileCount: Int
    let changedCount: Int
    let additions: Int
    let deletions: Int
    let hasSubfolders: Bool
}

indirect enum CommitFileTreeNode: Equatable, Sendable {
    case folder(CommitFileTreeFolder, children: [CommitFileTreeNode])
    case file(CommitFileTreeEntry)
}

enum CommitTreeRowID: Hashable, Sendable {
    case folder(String)
    case file(String)
}

struct CommitTreeRow: Identifiable, Equatable, Sendable {
    let id: CommitTreeRowID
    let depth: Int
    let kind: Kind

    enum Kind: Equatable, Sendable {
        case folder(CommitFileTreeFolder, isExpanded: Bool)
        case file(CommitFileTreeEntry)
    }
}

struct CommitFileTree: Equatable, Sendable {
    let roots: [CommitFileTreeNode]
    let folderPaths: Set<String>
    let unmodifiedFolderPaths: Set<String>
    let descendantFolders: [String: Set<String>]
    let entriesByPath: [String: CommitFileTreeEntry]
    let firstFilePath: String?
    let firstChangedFilePath: String?

    static let empty = CommitFileTree(
        roots: [],
        folderPaths: [],
        unmodifiedFolderPaths: [],
        descendantFolders: [:],
        entriesByPath: [:],
        firstFilePath: nil,
        firstChangedFilePath: nil
    )

    var hasFolders: Bool { !folderPaths.isEmpty }
    var filePaths: Set<String> { Set(entriesByPath.keys) }

    func flattenedRows(collapsed: Set<String>) -> [CommitTreeRow] {
        var rows: [CommitTreeRow] = []
        func append(_ nodes: [CommitFileTreeNode], depth: Int) {
            for node in nodes {
                switch node {
                case .folder(let folder, let children):
                    let expanded = !collapsed.contains(folder.path)
                    rows.append(CommitTreeRow(id: .folder(folder.path), depth: depth, kind: .folder(folder, isExpanded: expanded)))
                    if expanded {
                        append(children, depth: depth + 1)
                    }
                case .file(let entry):
                    rows.append(CommitTreeRow(id: .file(entry.path), depth: depth, kind: .file(entry)))
                }
            }
        }
        append(roots, depth: 0)
        return rows
    }

    func ancestorFolders(of filePath: String) -> Set<String> {
        guard !folderPaths.isEmpty else { return [] }
        var ancestors: Set<String> = []
        var index = filePath.startIndex
        while let slash = filePath[index...].firstIndex(of: "/") {
            let candidate = String(filePath[..<slash])
            if folderPaths.contains(candidate) {
                ancestors.insert(candidate)
            }
            index = filePath.index(after: slash)
        }
        return ancestors
    }

    func filePaths(inFolder folderPath: String) -> [String] {
        let prefix = folderPath + "/"
        return entriesByPath.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    func existingFilePaths(inFolder folderPath: String) -> [String] {
        let prefix = folderPath + "/"
        return entriesByPath.values
            .filter { $0.path.hasPrefix(prefix) && $0.change?.status != "D" }
            .map(\.path)
            .sorted()
    }

    nonisolated static func build(
        changes: [ChangedPath],
        statistics: [String: FileStatistics],
        allPaths: [String]? = nil
    ) -> CommitFileTree {
        let changesByPath = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var orderedEntries: [CommitFileTreeEntry] = []
        var entriesByPath: [String: CommitFileTreeEntry] = [:]

        if let allPaths {
            var seen: Set<String> = []
            for path in allPaths where seen.insert(path).inserted {
                let entry = CommitFileTreeEntry(path: path, change: changesByPath[path], stats: statistics[path])
                orderedEntries.append(entry)
                entriesByPath[path] = entry
            }
            // Keep deleted files visible when browsing the commit snapshot alongside changes.
            for change in changes where seen.insert(change.path).inserted {
                let entry = CommitFileTreeEntry(path: change.path, change: change, stats: statistics[change.path])
                orderedEntries.append(entry)
                entriesByPath[change.path] = entry
            }
        } else {
            for change in changes where entriesByPath[change.path] == nil {
                let entry = CommitFileTreeEntry(path: change.path, change: change, stats: statistics[change.path])
                orderedEntries.append(entry)
                entriesByPath[change.path] = entry
            }
        }

        guard !orderedEntries.isEmpty else { return .empty }

        final class Builder {
            let segment: String
            let path: String
            var subfolders: [String: Builder] = [:]
            var files: [CommitFileTreeEntry] = []

            init(segment: String, path: String) {
                self.segment = segment
                self.path = path
            }
        }

        let root = Builder(segment: "", path: "")
        for entry in orderedEntries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            if components.count <= 1 {
                root.files.append(entry)
                continue
            }
            var current = root
            for part in components.dropLast() {
                let name = String(part)
                if let existing = current.subfolders[name] {
                    current = existing
                } else {
                    let childPath = current.path.isEmpty ? name : "\(current.path)/\(name)"
                    let child = Builder(segment: name, path: childPath)
                    current.subfolders[name] = child
                    current = child
                }
            }
            current.files.append(entry)
        }

        var folderPaths: Set<String> = []
        var unmodifiedFolderPaths: Set<String> = []
        var descendantFolders: [String: Set<String>] = [:]

        func sortFiles(_ entries: [CommitFileTreeEntry]) -> [CommitFileTreeEntry] {
            entries.sorted { left, right in
                let leftName = (left.path as NSString).lastPathComponent
                let rightName = (right.path as NSString).lastPathComponent
                let comparison = leftName.localizedStandardCompare(rightName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return left.path.localizedStandardCompare(right.path) == .orderedAscending
            }
        }

        struct FolderBuildResult {
            let folder: CommitFileTreeFolder
            let node: CommitFileTreeNode
            let descendants: Set<String>
        }

        func buildFolder(_ builder: Builder) -> FolderBuildResult {
            var current = builder
            var segments = [builder.segment]
            while current.files.isEmpty && current.subfolders.count == 1,
                  let onlyChild = current.subfolders.values.first {
                segments.append(onlyChild.segment)
                current = onlyChild
            }

            let displayName = segments.joined(separator: "/")
            let folderPath = current.path

            let builtSubfolders = current.subfolders.values
                .map(buildFolder)
                .sorted { left, right in
                    let comparison = left.folder.name.localizedStandardCompare(right.folder.name)
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                    return left.folder.path.localizedStandardCompare(right.folder.path) == .orderedAscending
                }

            let sortedFiles = sortFiles(current.files)

            var fileCount = sortedFiles.count
            var changedCount = 0
            var additions = 0
            var deletions = 0
            var descendants: Set<String> = []

            for entry in sortedFiles {
                if entry.isChanged { changedCount += 1 }
                if let stats = entry.stats, !stats.isBinary {
                    additions += stats.additions
                    deletions += stats.deletions
                }
            }

            for sub in builtSubfolders {
                fileCount += sub.folder.fileCount
                changedCount += sub.folder.changedCount
                additions += sub.folder.additions
                deletions += sub.folder.deletions
                descendants.insert(sub.folder.path)
                descendants.formUnion(sub.descendants)
            }

            let folder = CommitFileTreeFolder(
                path: folderPath,
                name: displayName,
                fileCount: fileCount,
                changedCount: changedCount,
                additions: additions,
                deletions: deletions,
                hasSubfolders: !builtSubfolders.isEmpty
            )
            folderPaths.insert(folderPath)
            if changedCount == 0 {
                unmodifiedFolderPaths.insert(folderPath)
            }
            descendantFolders[folderPath] = descendants

            let children = builtSubfolders.map(\.node) + sortedFiles.map { CommitFileTreeNode.file($0) }
            return FolderBuildResult(folder: folder, node: .folder(folder, children: children), descendants: descendants)
        }

        let rootFolders = root.subfolders.values
            .map(buildFolder)
            .sorted { left, right in
                let comparison = left.folder.name.localizedStandardCompare(right.folder.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return left.folder.path.localizedStandardCompare(right.folder.path) == .orderedAscending
            }
        let rootFiles = sortFiles(root.files).map { CommitFileTreeNode.file($0) }
        let roots = rootFolders.map(\.node) + rootFiles

        var firstFilePath: String?
        var firstChangedFilePath: String?
        func scanFirst(_ nodes: [CommitFileTreeNode]) {
            for node in nodes {
                if firstFilePath != nil && firstChangedFilePath != nil { return }
                switch node {
                case .folder(_, let children):
                    scanFirst(children)
                case .file(let entry):
                    if firstFilePath == nil { firstFilePath = entry.path }
                    if firstChangedFilePath == nil, entry.isChanged { firstChangedFilePath = entry.path }
                }
            }
        }
        scanFirst(roots)

        return CommitFileTree(
            roots: roots,
            folderPaths: folderPaths,
            unmodifiedFolderPaths: unmodifiedFolderPaths,
            descendantFolders: descendantFolders,
            entriesByPath: entriesByPath,
            firstFilePath: firstFilePath,
            firstChangedFilePath: firstChangedFilePath
        )
    }
}
