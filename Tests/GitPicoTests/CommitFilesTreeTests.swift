import AppKit
import Foundation
@testable import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test func commitFileTreeBuildsChangedOnlyTreeCompactsChainsAndKeepsDeletedFilesWhenShowingAll() throws {
    let changes = [
        ChangedPath(status: "M", path: "README.md"),
        ChangedPath(status: "A", path: "Sources/GitPico/Views/NewTree.swift"),
        ChangedPath(status: "M", path: "Sources/GitPico/Views/WorkingCopyView.swift"),
        ChangedPath(status: "D", path: "Sources/GitPico/Legacy/Old.swift")
    ]
    let stats: [String: FileStatistics] = [
        "README.md": FileStatistics(additions: 3, deletions: 1, isBinary: false),
        "Sources/GitPico/Views/NewTree.swift": FileStatistics(additions: 120, deletions: 0, isBinary: false),
        "Sources/GitPico/Views/WorkingCopyView.swift": FileStatistics(additions: 24, deletions: 8, isBinary: false),
        "Sources/GitPico/Legacy/Old.swift": FileStatistics(additions: 0, deletions: 40, isBinary: false)
    ]

    let changedTree = CommitFileTree.build(changes: changes, statistics: stats)
    #expect(changedTree.hasFolders)
    #expect(changedTree.folderPaths == Set(["Sources/GitPico", "Sources/GitPico/Legacy", "Sources/GitPico/Views"]))
    #expect(changedTree.unmodifiedFolderPaths.isEmpty)
    #expect(changedTree.firstChangedFilePath == "Sources/GitPico/Legacy/Old.swift")
    #expect(changedTree.existingFilePaths(inFolder: "Sources/GitPico/Legacy").isEmpty)
    #expect(changedTree.existingFilePaths(inFolder: "Sources/GitPico/Views") == [
        "Sources/GitPico/Views/NewTree.swift",
        "Sources/GitPico/Views/WorkingCopyView.swift"
    ])

    let changedRows = changedTree.flattenedRows(collapsed: [])
    let folderByPath = Dictionary(uniqueKeysWithValues: changedRows.compactMap { row -> (String, CommitFileTreeFolder)? in
        if case .folder(let folder, _) = row.kind { return (folder.path, folder) }
        return nil
    })
    #expect(folderByPath["Sources/GitPico"]?.fileCount == 3)
    #expect(folderByPath["Sources/GitPico"]?.additions == 144)
    #expect(folderByPath["Sources/GitPico"]?.deletions == 48)
    #expect(folderByPath["Sources/GitPico/Views"]?.name == "Views")

    // Show All Files includes untouched files, flags unmodified folders, and keeps deleted files.
    let snapshotPaths = [
        ".gitignore",
        "Docs/Architecture/Overview.md",
        "README.md",
        "Sources/GitPico/Views/NewTree.swift",
        "Sources/GitPico/Views/WorkingCopyView.swift"
    ]
    let fullTree = CommitFileTree.build(changes: changes, statistics: stats, allPaths: snapshotPaths)
    #expect(fullTree.entriesByPath["Docs/Architecture/Overview.md"]?.isChanged == false)
    #expect(fullTree.entriesByPath["Sources/GitPico/Legacy/Old.swift"]?.change?.status == "D")
    #expect(fullTree.unmodifiedFolderPaths == Set(["Docs/Architecture"]))
    #expect(!fullTree.unmodifiedFolderPaths.contains("Sources/GitPico"))
}

@MainActor private func collectTableViews(in view: NSView, into result: inout [NSTableView]) {
    if let table = view as? NSTableView { result.append(table) }
    for subview in view.subviews {
        collectTableViews(in: subview, into: &result)
    }
}

@Test @MainActor func commitFilesTreeViewShowsChangedTreeAndDiffSplitWithoutWindows() async throws {
    let fixture = try await WorkingAppFixture.make(); defer { fixture.clean() }
    let root = await fixture.repository.root
    func writeFile(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // Base commit with both untouched and soon-to-be-changed files.
    try writeFile(".gitignore", ".DS_Store\n")
    try writeFile("docs/Guide.md", "# Guide\nUntouched doc\n")
    try writeFile("Design/Tokens/Colors.swift", "let accent = 0x111111\n")
    try writeFile("apps/macOS/App.swift", "struct App {\n    let version = 1\n}\n")
    try writeFile("apps/macOS/Legacy.swift", "// old file\n")
    try writeFile("README.md", "# Liltpaper\n")
    _ = try await GitProcess.run(["add", "-A"], at: root)
    _ = try await GitProcess.run(["commit", "-m", "Base layout"], at: root)

    // Target commit changes only a subset of files across nested directories.
    try writeFile("Design/Tokens/Colors.swift", "let accent = 0x7A3CFF\nlet surface = 0xFFFFFF\n")
    try writeFile("apps/macOS/App.swift", "struct App {\n    let version = 2\n    let treeMode = true\n}\n")
    try writeFile("apps/macOS/TreeView.swift", "struct TreeView {}\n")
    try FileManager.default.removeItem(at: root.appendingPathComponent("apps/macOS/Legacy.swift"))
    try writeFile("README.md", "# Liltpaper\nAdded commit tree view.\n")
    _ = try await GitProcess.run(["add", "-A"], at: root)
    _ = try await GitProcess.run(["commit", "-m", "Add commit file tree"], at: root)

    try await fixture.sync()
    fixture.store.navigate(.history)
    await fixture.store.historyTask?.value
    await fixture.store.detailTask?.value
    let commit = try #require(fixture.store.selectedCommit)
    let detail = try #require(fixture.store.commitDetail)
    #expect(detail.files.count == 5)

    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.tabbingMode = .disallowed
    window.styleMask = [.borderless]
    window.contentMinSize = .zero
    window.setFrame(NSRect(x: -10000, y: -10000, width: 1020, height: 620), display: false)

    let host = NSHostingView(
        rootView: CommitDetailView(store: fixture.store, initialTree: true)
            .background(Color(nsColor: .windowBackgroundColor))
    )
    window.contentView = host
    defer { window.contentView = nil; window.close() }

    func settle() async throws -> (treeTable: NSTableView, diffTables: [DiffTableView]) {
        for _ in 0..<24 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        var allTables: [NSTableView] = []
        collectTableViews(in: host, into: &allTables)
        let treeTable = try #require(allTables.first { !($0 is DiffTableView) })
        let diffTables = allTables.compactMap { $0 as? DiffTableView }
        return (treeTable, diffTables)
    }

    let (treeTable, diffTables) = try await settle()
    // 2 compacted folders (apps/macOS, Design/Tokens) + 5 changed files = 7 rows (untouched docs/Guide.md & .gitignore excluded).
    let expectedTree = CommitFileTree.build(changes: detail.files, statistics: detail.statistics)
    #expect(expectedTree.flattenedRows(collapsed: []).count == 7)
    #expect(treeTable.numberOfRows == 7)
    // First changed file is auto-selected and its diff renders immediately on the right pane.
    #expect(!diffTables.isEmpty)
    #expect(diffTables.contains { $0.numberOfRows > 0 })

    if let captureDir = ProcessInfo.processInfo.environment["GITPICO_COMMIT_TREE_CAPTURE_DIR"] {
        let output = URL(fileURLWithPath: captureDir, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            _ = try await settle()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("commit-files-tree-\(dark ? "dark" : "light").png"))
        }
    }

    #expect(!NSApplication.shared.isActive && NSApplication.shared.windows.filter(\.isVisible).isEmpty)
}
