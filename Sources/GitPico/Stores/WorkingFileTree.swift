import Foundation
import GitCore

enum WorkingFolderStageState: Equatable, Sendable {
    case none
    case unstaged
    case mixed
    case staged
    case conflicted
}

struct WorkingFileTreeFolder: Equatable, Sendable {
    let path: String
    let name: String
    let fileCount: Int
    let changedCount: Int
    let stageableCount: Int
    let unstageableCount: Int
    let conflictedCount: Int
    let hasSubfolders: Bool

    var hasChanges: Bool { changedCount > 0 }
    var nonConflictedChangedCount: Int { changedCount - conflictedCount }
    var stageState: WorkingFolderStageState {
        guard changedCount > 0 else { return .none }
        if stageableCount == 0 && unstageableCount == 0 && conflictedCount > 0 { return .conflicted }
        if unstageableCount > 0 && stageableCount == 0 { return .staged }
        if unstageableCount > 0 && stageableCount > 0 { return .mixed }
        return .unstaged
    }
}

indirect enum WorkingFileTreeNode: Equatable, Sendable {
    case folder(WorkingFileTreeFolder, children: [WorkingFileTreeNode])
    case file(WorkingFileEntry)
}

enum WorkingTreeRowID: Hashable, Sendable {
    case folder(String)
    case file(String)
}

struct WorkingTreeRow: Identifiable, Equatable, Sendable {
    let id: WorkingTreeRowID
    let depth: Int
    let kind: Kind

    enum Kind: Equatable, Sendable {
        case folder(WorkingFileTreeFolder, isExpanded: Bool)
        case file(WorkingFileEntry)
    }
}

struct WorkingFileTree: Equatable, Sendable {
    let roots: [WorkingFileTreeNode]
    let folderPaths: Set<String>
    let descendantFolders: [String: Set<String>]

    static let empty = WorkingFileTree(roots: [], folderPaths: [], descendantFolders: [:])
    var hasFolders: Bool { !folderPaths.isEmpty }

    func flattenedRows(collapsed: Set<String>) -> [WorkingTreeRow] {
        var rows: [WorkingTreeRow] = []
        func append(_ nodes: [WorkingFileTreeNode], depth: Int) {
            for node in nodes {
                switch node {
                case .folder(let folder, let children):
                    let expanded = !collapsed.contains(folder.path)
                    rows.append(WorkingTreeRow(id: .folder(folder.path), depth: depth, kind: .folder(folder, isExpanded: expanded)))
                    if expanded {
                        append(children, depth: depth + 1)
                    }
                case .file(let entry):
                    rows.append(WorkingTreeRow(id: .file(entry.path), depth: depth, kind: .file(entry)))
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

    nonisolated static func build(files: [WorkingFileEntry], orderByStatus: Bool) -> WorkingFileTree {
        guard !files.isEmpty else { return .empty }

        final class Builder {
            let segment: String
            let path: String
            var subfolders: [String: Builder] = [:]
            var files: [WorkingFileEntry] = []

            init(segment: String, path: String) {
                self.segment = segment
                self.path = path
            }
        }

        let root = Builder(segment: "", path: "")
        for entry in files {
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
        var descendantFolders: [String: Set<String>] = [:]

        func sortFiles(_ entries: [WorkingFileEntry]) -> [WorkingFileEntry] {
            entries.sorted { left, right in
                if orderByStatus, left.status != right.status {
                    return left.status.localizedStandardCompare(right.status) == .orderedAscending
                }
                let leftName = (left.path as NSString).lastPathComponent
                let rightName = (right.path as NSString).lastPathComponent
                let comparison = leftName.localizedStandardCompare(rightName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return left.path.localizedStandardCompare(right.path) == .orderedAscending
            }
        }

        struct FolderBuildResult {
            let folder: WorkingFileTreeFolder
            let node: WorkingFileTreeNode
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
            var stageableCount = 0
            var unstageableCount = 0
            var conflictedCount = 0
            var descendants: Set<String> = []

            for entry in sortedFiles {
                guard let change = entry.change else { continue }
                changedCount += 1
                if change.isConflicted {
                    conflictedCount += 1
                } else {
                    if change.isUnstaged { stageableCount += 1 }
                    if change.isStaged { unstageableCount += 1 }
                }
            }

            for sub in builtSubfolders {
                fileCount += sub.folder.fileCount
                changedCount += sub.folder.changedCount
                stageableCount += sub.folder.stageableCount
                unstageableCount += sub.folder.unstageableCount
                conflictedCount += sub.folder.conflictedCount
                descendants.insert(sub.folder.path)
                descendants.formUnion(sub.descendants)
            }

            let folder = WorkingFileTreeFolder(
                path: folderPath,
                name: displayName,
                fileCount: fileCount,
                changedCount: changedCount,
                stageableCount: stageableCount,
                unstageableCount: unstageableCount,
                conflictedCount: conflictedCount,
                hasSubfolders: !builtSubfolders.isEmpty
            )
            folderPaths.insert(folderPath)
            descendantFolders[folderPath] = descendants

            let children = builtSubfolders.map(\.node) + sortedFiles.map { WorkingFileTreeNode.file($0) }
            return FolderBuildResult(folder: folder, node: .folder(folder, children: children), descendants: descendants)
        }

        let rootFolders = root.subfolders.values
            .map(buildFolder)
            .sorted { left, right in
                let comparison = left.folder.name.localizedStandardCompare(right.folder.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return left.folder.path.localizedStandardCompare(right.folder.path) == .orderedAscending
            }
        let rootFiles = sortFiles(root.files).map { WorkingFileTreeNode.file($0) }
        return WorkingFileTree(
            roots: rootFolders.map(\.node) + rootFiles,
            folderPaths: folderPaths,
            descendantFolders: descendantFolders
        )
    }
}
