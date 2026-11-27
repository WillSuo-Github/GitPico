import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test func workingFileTreeCompactsSingleChildChainsSortsFoldersFirstAndAggregatesStageStates() throws {
    let rawStatus = [
        " M Bittorrent-macOS.xcconfig",
        " M Bittorrent-macOS/Bridge/LibtorrentWrapper.mm",
        "M  Bittorrent-macOS/Localizable.xcstrings",
        "MM Scripts/libtorrent/build-universal.sh",
        "?? Scripts/libtorrent/patches/0001-fix.patch",
        " M Vendor/libtorrent/build-manifest.json",
        "M  Vendor/libtorrent/include/libtorrent/add_torrent_params.hpp",
        " D Vendor/libtorrent/include/libtorrent/aux_/aligned_union.hpp",
        " M Vendor/libtorrent/include/libtorrent/aux_/alert_manager.hpp",
        "UU Conflicts/only-conflict.txt",
        " D foo",
        "?? foo/bar.txt"
    ].joined(separator: "\0") + "\0"

    let changes = GitParser.status(Data(rawStatus.utf8))
    var entries = changes.map {
        WorkingFileEntry(path: $0.path, change: $0, isTracked: !$0.isUntracked, isIgnored: false, assumeUnchanged: false, skipWorktree: false)
    }
    entries.append(WorkingFileEntry(path: "Docs/Guide/README.md", change: nil, isTracked: true, isIgnored: false, assumeUnchanged: false, skipWorktree: false))

    let tree = WorkingFileTree.build(files: entries, orderByStatus: false)
    #expect(tree.hasFolders)
    #expect(tree.folderPaths == Set([
        "Bittorrent-macOS",
        "Bittorrent-macOS/Bridge",
        "Conflicts",
        "Docs/Guide",
        "Scripts/libtorrent",
        "Scripts/libtorrent/patches",
        "Vendor/libtorrent",
        "Vendor/libtorrent/include/libtorrent",
        "Vendor/libtorrent/include/libtorrent/aux_",
        "foo"
    ]))

    let allRows = tree.flattenedRows(collapsed: [])
    let rootNames: [String] = tree.roots.map { node in
        switch node {
        case .folder(let folder, _): "dir:\(folder.name)"
        case .file(let entry): "file:\(entry.path)"
        }
    }
    #expect(rootNames == [
        "dir:Bittorrent-macOS",
        "dir:Conflicts",
        "dir:Docs/Guide",
        "dir:foo",
        "dir:Scripts/libtorrent",
        "dir:Vendor/libtorrent",
        "file:Bittorrent-macOS.xcconfig",
        "file:foo"
    ])

    func folder(at path: String) throws -> WorkingFileTreeFolder {
        for row in allRows {
            if case .folder(let folder, _) = row.kind, folder.path == path { return folder }
        }
        throw NSError(domain: "WorkingCopyTreeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing folder \(path)"])
    }

    let bittorrent = try folder(at: "Bittorrent-macOS")
    #expect(bittorrent.fileCount == 2 && bittorrent.changedCount == 2 && bittorrent.stageState == .mixed)

    let bridge = try folder(at: "Bittorrent-macOS/Bridge")
    #expect(bridge.name == "Bridge" && bridge.fileCount == 1 && bridge.stageState == .unstaged)

    let scripts = try folder(at: "Scripts/libtorrent")
    #expect(scripts.name == "Scripts/libtorrent" && scripts.fileCount == 2 && scripts.stageState == .mixed)
    #expect(scripts.stageableCount == 2 && scripts.unstageableCount == 1)

    let vendor = try folder(at: "Vendor/libtorrent")
    #expect(vendor.name == "Vendor/libtorrent" && vendor.fileCount == 4 && vendor.stageState == .mixed)

    let includeDir = try folder(at: "Vendor/libtorrent/include/libtorrent")
    #expect(includeDir.name == "include/libtorrent" && includeDir.fileCount == 3 && includeDir.stageState == .mixed)

    let conflicts = try folder(at: "Conflicts")
    #expect(conflicts.conflictedCount == 1 && conflicts.stageState == .conflicted)

    let docs = try folder(at: "Docs/Guide")
    #expect(docs.fileCount == 1 && docs.changedCount == 0 && docs.stageState == .none)

    let ancestors = tree.ancestorFolders(of: "Vendor/libtorrent/include/libtorrent/aux_/alert_manager.hpp")
    #expect(ancestors == Set([
        "Vendor/libtorrent",
        "Vendor/libtorrent/include/libtorrent",
        "Vendor/libtorrent/include/libtorrent/aux_"
    ]))

    let collapsedVendor = tree.flattenedRows(collapsed: ["Vendor/libtorrent"])
    #expect(!collapsedVendor.contains {
        if case .file(let entry) = $0.kind { return entry.path.hasPrefix("Vendor/libtorrent/") }
        if case .folder(let folder, _) = $0.kind { return folder.path.hasPrefix("Vendor/libtorrent/") }
        return false
    })
    #expect(collapsedVendor.contains {
        if case .folder(let folder, let expanded) = $0.kind { return folder.path == "Vendor/libtorrent" && !expanded }
        return false
    })

    let byStatus = WorkingFileTree.build(files: entries, orderByStatus: true)
    let auxRowFiles: [String] = byStatus.flattenedRows(collapsed: []).compactMap { row in
        if case .file(let entry) = row.kind, entry.path.hasPrefix("Vendor/libtorrent/include/libtorrent/aux_/") {
            return entry.path
        }
        return nil
    }
    #expect(auxRowFiles == [
        "Vendor/libtorrent/include/libtorrent/aux_/aligned_union.hpp",
        "Vendor/libtorrent/include/libtorrent/aux_/alert_manager.hpp"
    ])
}

@MainActor private func writeNested(_ fixture: WorkingAppFixture, _ relativePath: String, _ contents: String) async throws {
    let url = await fixture.repository.root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
}

@Test @MainActor func workingTreeFolderActionsStageUnstageDiscardStashAndRespectFilter() async throws {
    let fixture = try await WorkingAppFixture.make(); defer { fixture.clean() }
    try await writeNested(fixture, "Scripts/lib/keep.sh", "echo keep\n")
    try await writeNested(fixture, "Scripts/libtorrent/build.sh", "echo build\n")
    try await writeNested(fixture, "Scripts/libtorrent/patches/p1.patch", "diff 1\n")
    try await writeNested(fixture, "Vendor/libtorrent/manifest.json", "{}\n")
    try await writeNested(fixture, "Vendor/libtorrent/include/libtorrent/aux_/a.hpp", "int a;\n")
    try await writeNested(fixture, "Vendor/libtorrent/include/libtorrent/aux_/b.hpp", "int b;\n")
    try await fixture.sync()

    #expect(fixture.store.hasWorkingTreeFolders)
    #expect(fixture.store.canCollapseAllWorkingFolders)
    #expect(!fixture.store.canExpandAllWorkingFolders)

    // Prefix safety: staging Scripts/lib must not stage Scripts/libtorrent/*.
    fixture.store.stageWorkingFolder("Scripts/lib")
    await fixture.finish()
    #expect(fixture.store.staged.map(\.path) == ["Scripts/lib/keep.sh"])
    #expect(fixture.store.changes.first { $0.path == "Scripts/libtorrent/build.sh" }?.isStaged == false)

    // Toggle folder checkbox stages all unstaged files in that subtree, then unstages all of them.
    fixture.store.toggleWorkingFolder("Vendor/libtorrent/include/libtorrent/aux_")
    await fixture.finish()
    #expect(Set(fixture.store.staged.map(\.path)) == Set([
        "Scripts/lib/keep.sh",
        "Vendor/libtorrent/include/libtorrent/aux_/a.hpp",
        "Vendor/libtorrent/include/libtorrent/aux_/b.hpp"
    ]))

    // Parent Vendor/libtorrent is now mixed (2 staged + 1 unstaged): toggling it stages remaining file.
    let vendorBefore = fixture.store.visibleWorkingTreeRows.compactMap { row -> WorkingFileTreeFolder? in
        if case .folder(let folder, _) = row.kind, folder.path == "Vendor/libtorrent" { return folder }
        return nil
    }.first
    #expect(vendorBefore?.stageState == .mixed)

    fixture.store.toggleWorkingFolder("Vendor/libtorrent")
    await fixture.finish()
    let vendorStaged = fixture.store.visibleWorkingTreeRows.compactMap { row -> WorkingFileTreeFolder? in
        if case .folder(let folder, _) = row.kind, folder.path == "Vendor/libtorrent" { return folder }
        return nil
    }.first
    #expect(vendorStaged?.stageState == .staged)

    // Toggling a fully staged folder unstages all files under it.
    fixture.store.toggleWorkingFolder("Vendor/libtorrent")
    await fixture.finish()
    #expect(fixture.store.changes.filter { $0.path.hasPrefix("Vendor/libtorrent/") }.allSatisfy { !$0.isStaged })

    // Filter safety: searching "aux_" restricts folder staging strictly to visible matching files.
    fixture.store.toggleWorkingFolderExpansion("Vendor/libtorrent", recursive: true)
    #expect(fixture.store.collapsedWorkingFolders.contains("Vendor/libtorrent"))
    #expect(fixture.store.collapsedWorkingFolders.contains("Vendor/libtorrent/include/libtorrent/aux_"))

    fixture.store.search = "aux_"
    await fixture.store.rebuildWorkingList()
    // Search auto-expands matching folders without discarding the user's normal collapsed set.
    #expect(fixture.store.visibleWorkingTreeRows.contains {
        if case .file(let entry) = $0.kind { return entry.path == "Vendor/libtorrent/include/libtorrent/aux_/a.hpp" }
        return false
    })
    fixture.store.stageWorkingFolder("Vendor/libtorrent")
    await fixture.finish()
    #expect(fixture.store.changes.first { $0.path == "Vendor/libtorrent/include/libtorrent/aux_/a.hpp" }?.isStaged == true)
    #expect(fixture.store.changes.first { $0.path == "Vendor/libtorrent/include/libtorrent/aux_/b.hpp" }?.isStaged == true)
    #expect(fixture.store.changes.first { $0.path == "Vendor/libtorrent/manifest.json" }?.isStaged == false)

    // Clearing search restores the user's collapsed folders.
    fixture.store.search = ""
    await fixture.store.rebuildWorkingList()
    #expect(fixture.store.collapsedWorkingFolders.contains("Vendor/libtorrent"))
    #expect(!fixture.store.visibleWorkingTreeRows.contains {
        if case .file(let entry) = $0.kind { return entry.path == "Vendor/libtorrent/manifest.json" }
        return false
    })

    // Expand All & Collapse All.
    fixture.store.expandAllWorkingFolders()
    #expect(fixture.store.collapsedWorkingFolders.isEmpty && !fixture.store.canExpandAllWorkingFolders)
    fixture.store.collapseAllWorkingFolders()
    #expect(fixture.store.collapsedWorkingFolders == fixture.store.workingList.tree.folderPaths)
    #expect(!fixture.store.canCollapseAllWorkingFolders && fixture.store.canExpandAllWorkingFolders)

    // Discard & Stash folder actions produce exact folder-scoped requests.
    fixture.store.discardWorkingFolder("Scripts/libtorrent")
    guard case .discard(let discardPaths) = fixture.store.localChangeRequest?.action else {
        Issue.record("Expected discard request for folder")
        return
    }
    #expect(discardPaths == ["Scripts/libtorrent/build.sh", "Scripts/libtorrent/patches/p1.patch"])
    fixture.store.localChangeRequest = nil

    fixture.store.stashWorkingFolder("Scripts/libtorrent")
    for _ in 0..<20 where fixture.store.stashRequest == nil {
        try await Task.sleep(for: .milliseconds(25))
    }
    guard case .save(let stashPaths, false) = fixture.store.stashRequest?.action else {
        Issue.record("Expected stash save request for folder")
        return
    }
    #expect(stashPaths == ["Scripts/libtorrent/build.sh", "Scripts/libtorrent/patches/p1.patch"])
    fixture.store.stashRequest = nil
    #expect(!NSApplication.shared.isActive && NSApplication.shared.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func workingTreeViewPreferencePersistsAcrossLaunches() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-tree-pref-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("preferences.json")

    let initial = AppPreferences(file: file)
    #expect(!initial.workingTreeView)
    initial.workingTreeView = true
    #expect(AppPreferences(file: file).workingTreeView)
    initial.workingTreeView = false
    #expect(!AppPreferences(file: file).workingTreeView)
}

@MainActor private func findWorkingListTableView(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView, !(table is DiffTableView) { return table }
    for subview in view.subviews {
        if let found = findWorkingListTableView(in: subview) { return found }
    }
    return nil
}

@Test @MainActor func workingCopyViewTreeModeRendersSelectionAndCollapseWithoutWindows() async throws {
    let fixture = try await WorkingAppFixture.make(); defer { fixture.clean() }
    let previousTree = AppPreferences.shared.workingTreeView
    defer { AppPreferences.shared.workingTreeView = previousTree }

    try await writeNested(fixture, "Bittorrent-macOS.xcconfig", "A = 1\n")
    try await writeNested(fixture, "Bittorrent-macOS/Bridge/LibtorrentWrapper.mm", "// wrapper\n")
    try await writeNested(fixture, "Bittorrent-macOS/Localizable.xcstrings", "{}\n")
    try await writeNested(fixture, "Config/App-Common.xcconfig", "B = 2\n")
    try await writeNested(fixture, "Scripts/libtorrent/build-universal.sh", "#!/bin/sh\n")
    try await writeNested(fixture, "Scripts/libtorrent/patches/0001-fix.patch", "patch 1\n")
    try await writeNested(fixture, "Scripts/libtorrent/patches/0002-restore.patch", "patch 2\n")
    try await writeNested(fixture, "Vendor/libtorrent/build-manifest.json", "{}\n")
    try await writeNested(fixture, "Vendor/libtorrent/include/libtorrent/add_torrent_params.hpp", "struct P {};\n")
    try await writeNested(fixture, "Vendor/libtorrent/include/libtorrent/address.hpp", "struct A {};\n")
    try await writeNested(fixture, "Vendor/libtorrent/include/libtorrent/aux_/alert_manager.hpp", "struct M {};\n")
    try await writeNested(fixture, "Vendor/libtorrent/include/libtorrent/aux_/alloca.hpp", "struct L {};\n")
    try await fixture.sync()

    // Stage one file inside Bittorrent-macOS and all files in Config so we exercise unstaged, mixed, and staged checkboxes.
    fixture.store.stage(fixture.store.changes.filter {
        $0.path == "Bittorrent-macOS/Localizable.xcstrings" || $0.path == "Config/App-Common.xcconfig"
    })
    await fixture.finish()

    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.tabbingMode = .disallowed
    window.styleMask = [.borderless]
    window.contentMinSize = .zero
    window.setFrame(NSRect(x: -10000, y: -10000, width: 980, height: 680), display: false)
    let host = NSHostingView(rootView: WorkingCopyView(store: fixture.store))
    window.contentView = host
    defer { window.contentView = nil; window.close() }

    func settle() async throws -> NSTableView {
        for _ in 0..<18 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(findWorkingListTableView(in: host))
    }

    AppPreferences.shared.workingTreeView = false
    let flatTable = try await settle()
    let flatCount = fixture.store.workingList.files.count
    #expect(flatTable.numberOfRows == flatCount)

    fixture.store.setWorkingSelection(["Vendor/libtorrent/include/libtorrent/aux_/alert_manager.hpp"])
    AppPreferences.shared.workingTreeView = true
    let treeTable = try await settle()
    let expandedRowCount = fixture.store.visibleWorkingTreeRows.count
    #expect(expandedRowCount > flatCount)
    #expect(treeTable.numberOfRows == expandedRowCount)
    #expect(fixture.store.selectedWorkingFiles == ["Vendor/libtorrent/include/libtorrent/aux_/alert_manager.hpp"])
    #expect(fixture.store.selectedChange == "Vendor/libtorrent/include/libtorrent/aux_/alert_manager.hpp")

    // Multi-selection across different folders works and persists across Tree <-> Flat switches.
    let multi: Set<String> = [
        "Bittorrent-macOS/Bridge/LibtorrentWrapper.mm",
        "Vendor/libtorrent/include/libtorrent/aux_/alert_manager.hpp"
    ]
    fixture.store.setWorkingSelection(multi)
    _ = try await settle()
    #expect(fixture.store.selectedWorkingFiles == multi)
    AppPreferences.shared.workingTreeView = false
    _ = try await settle()
    #expect(fixture.store.selectedWorkingFiles == multi)
    AppPreferences.shared.workingTreeView = true
    let restoredTreeTable = try await settle()
    #expect(fixture.store.selectedWorkingFiles == multi)

    // Selecting rows directly on the underlying NSTableView across a folder row selects only tagged file rows.
    let rowsSnapshot = fixture.store.visibleWorkingTreeRows
    let bridgeFileRow = try #require(rowsSnapshot.firstIndex {
        if case .file(let entry) = $0.kind { return entry.path == "Bittorrent-macOS/Bridge/LibtorrentWrapper.mm" }
        return false
    })
    let configFolderRow = try #require(rowsSnapshot.firstIndex {
        if case .folder(let folder, _) = $0.kind { return folder.path == "Config" }
        return false
    })
    let configFileRow = try #require(rowsSnapshot.firstIndex {
        if case .file(let entry) = $0.kind { return entry.path == "Config/App-Common.xcconfig" }
        return false
    })
    restoredTreeTable.selectRowIndexes(IndexSet([bridgeFileRow, configFolderRow, configFileRow]), byExtendingSelection: false)
    _ = try await settle()
    #expect(fixture.store.selectedWorkingFiles == Set([
        "Bittorrent-macOS/Bridge/LibtorrentWrapper.mm",
        "Config/App-Common.xcconfig"
    ]))

    // Show All Files mixes tracked unmodified files with changed files cleanly in Tree mode.
    fixture.store.showAllFiles = true
    await fixture.store.refreshFileBrowser()
    await fixture.store.rebuildWorkingList()
    let allFilesTable = try await settle()
    #expect(allFilesTable.numberOfRows == fixture.store.visibleWorkingTreeRows.count)
    #expect(fixture.store.visibleWorkingTreeRows.contains {
        if case .file(let entry) = $0.kind { return entry.path == "a.txt" && entry.change == nil }
        return false
    })
    fixture.store.showAllFiles = false
    await fixture.store.rebuildWorkingList()
    _ = try await settle()

    // Collapsing a folder shrinks rendered table rows cleanly.
    fixture.store.toggleWorkingFolderExpansion("Scripts/libtorrent")
    let collapsedTable = try await settle()
    #expect(collapsedTable.numberOfRows < expandedRowCount)
    #expect(collapsedTable.numberOfRows == fixture.store.visibleWorkingTreeRows.count)

    if let captureDir = ProcessInfo.processInfo.environment["GITPICO_WORKING_TREE_CAPTURE_DIR"] {
        let output = URL(fileURLWithPath: captureDir, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        fixture.store.setWorkingSelection(["Vendor/libtorrent/include/libtorrent/aux_/alert_manager.hpp"])
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let table = try await settle()
            let leadingWidth = max(340, (table.enclosingScrollView?.frame.width ?? 340) + 12)
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            if let cg = rep.cgImage {
                let scale = cg.width / max(1, Int(host.bounds.width))
                let crop = CGRect(x: 0, y: 0, width: min(Int(leadingWidth) * scale, cg.width), height: cg.height)
                if let cropped = cg.cropping(to: crop),
                   let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) {
                    try png.write(to: output.appendingPathComponent("working-tree-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    #expect(!NSApplication.shared.isActive && NSApplication.shared.windows.filter(\.isVisible).isEmpty)
}
