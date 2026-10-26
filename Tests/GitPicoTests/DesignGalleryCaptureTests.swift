import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

/// Windowless capture of every primary destination for design review. Opt-in only; windows stay suppressed.
@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RENDER_DESIGN_GALLERY"] == "1", "Explicit suppressed design gallery capture only."))
@MainActor func renderDesignGalleryWithoutActivation() async throws {
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_DESIGN_GALLERY_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GitPico-gallery-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try await DesignGalleryFixture.make(in: root)

    let library = RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: [])
    let workspace = RepositoryWorkspace(library: library, draftsFile: root.appendingPathComponent("drafts.json"))
    for name in ["Costaware-iOS", "Website", "dotfiles"] {
        let url = root.appendingPathComponent(name)
        _ = try await GitRepository.create(at: url)
        let id = try library.register(url)
        if name == "Website" { try library.setFavorite([id], true) }
    }
    await workspace.open(repo)
    try library.rename([try #require(library.document.repositories.first { $0.path == repo.path }?.id)], to: "GitPico")
    let windows = NativeRepositoryWindows(workspace: workspace, permitsPresentation: false)
    windows.start()
    defer { windows.stop(); workspace.shutdown() }
    let tab = workspace.activeTab, store = tab.store
    let window = try #require(windows.window(for: tab.id))

    func settle(_ milliseconds: Int = 700) async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(milliseconds))
        await store.detailTask?.value
        await store.historyTask?.value
        for _ in 0..<10 { await Task.yield() }
    }
    func capture(_ name: String) async throws {
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1440, height: 900)), display: false)
            try await settle(400)
            let view = try #require(window.contentView?.superview)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    // Split-view sidebars draw through vibrancy that cacheDisplay omits, so render the sidebar separately.
    func captureSidebar() async throws {
        for dark in [false, true] {
            let host = NSHostingView(rootView: SidebarView(store: store).frame(width: 280, height: 860).background(Color(nsColor: .windowBackgroundColor)))
            let panel = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 280, height: 860), styleMask: [.borderless], backing: .buffered, defer: true)
            panel.isReleasedWhenClosed = false
            panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            panel.contentView = host
            host.layoutSubtreeIfNeeded()
            try await settle(600)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("00-sidebar-\(dark ? "dark" : "light").png"))
            panel.contentView = nil
            panel.close()
        }
    }

    try await settle()
    store.commitSubject = "Refine commit composer layout"
    store.setWorkingSelection(["Sources/App/ContentView.swift"])
    try await settle()
    try await capture("01-working-copy")
    try await captureSidebar()

    store.navigate(.history); try await settle(1200)
    if let commit = store.visibleCommits.dropFirst(1).first { store.selectCommit(commit) }
    try await settle(900)
    try await capture("02-history")

    store.navigate(.stashes); try await settle()
    if let stash = store.snapshot?.stashes.first { store.selectStash(stash) }
    try await settle()
    try await capture("03-stashes")

    store.navigate(.branchesReview); try await settle(1500)
    try await capture("04-branches-review")

    store.navigate(.reflog); try await settle(1200)
    try await capture("05-reflog")

    store.navigate(.repositorySettings); try await settle(1200)
    try await capture("06-settings")

    store.navigate(.worktrees); try await settle(900)
    try await capture("07-worktrees")

    store.navigate(.fileHistory("Sources/App/ContentView.swift", "HEAD")); try await settle(1500)
    try await capture("08-file-history")

    store.navigate(.comparison("HEAD~3")); try await settle(1500)
    try await capture("09-compare")

    store.navigate(.workingCopy); try await settle()
    workspace.showRepositories(from: store); try await settle(900)
    try await capture("10-repositories")
    workspace.returnToRepository(from: store)

    let conflict = try await DesignGalleryFixture.makeConflict(in: root)
    await workspace.open(conflict, from: store, replacing: true); try await settle(1200)
    store.setWorkingSelection(["Sources/App/Theme.swift"])
    try await settle(1200)
    try await capture("11-conflict")
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@MainActor enum DesignGalleryFixture {
    static func makeConflict(in root: URL) async throws -> URL {
        let url = root.appendingPathComponent("ConflictDemo")
        _ = try await GitRepository.create(at: url)
        func git(_ arguments: [String], allowed: Set<Int32> = [0]) async throws { _ = try await GitProcess.run(arguments, at: url, allowed: allowed) }
        for (key, value) in [("user.name", "Will Suo"), ("user.email", "will@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { try await git(["config", key, value]) }
        let file = url.appendingPathComponent("Sources/App/Theme.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        func write(_ accent: String) throws { try Data("import SwiftUI\n\nenum Theme {\n    static let accent = \(accent)\n    static let corner: CGFloat = 10\n}\n".utf8).write(to: file) }
        try write("Color.blue"); try await git(["add", "."]); try await git(["commit", "-q", "-m", "Add theme"])
        let base = try await GitProcess.run(["symbolic-ref", "--short", "HEAD"], at: url).text.trimmingCharacters(in: .whitespacesAndNewlines)
        try await git(["checkout", "-q", "-b", "feature/warm-accent"])
        try write("Color.orange"); try await git(["commit", "-q", "-am", "Use a warm accent"])
        try await git(["checkout", "-q", base])
        try write("Color.teal"); try await git(["commit", "-q", "-am", "Try a teal accent"])
        try await git(["merge", "feature/warm-accent"], allowed: [0, 1])
        return url
    }
    static func make(in root: URL) async throws -> URL {
        let origin = root.appendingPathComponent("origin.git")
        _ = try await GitProcess.run(["init", "--bare", "-b", "main", origin.path], at: root)
        let url = root.appendingPathComponent("GitPico")
        _ = try await GitRepository.create(at: url)
        func git(_ arguments: [String], author: (String, String)? = nil, date: Int? = nil) async throws {
            var args = arguments
            if let author { args = ["-c", "user.name=\(author.0)", "-c", "user.email=\(author.1)"] + args }
            _ = try await GitProcess.run(args, at: url, identityEnvironment: date.map { ["GIT_AUTHOR_DATE": "\($0) +0800", "GIT_COMMITTER_DATE": "\($0) +0800"] } ?? [:])
        }
        for (key, value) in [("user.name", "Will Suo"), ("user.email", "will@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("init.defaultBranch", "main")] { try await git(["config", key, value]) }
        func write(_ path: String, _ text: String) throws {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        let people = [("Will Suo", "will@example.invalid"), ("Mina Park", "mina@example.invalid"), ("Leo Chen", "leo@example.invalid")]
        var clock = 1_792_700_000
        func commit(_ message: String, by index: Int, files: [String: String]) async throws {
            for (path, text) in files { try write(path, text) }
            try await git(["add", "-A"])
            clock += 5_400
            try await git(["commit", "-q", "-m", message], author: people[index % people.count], date: clock)
        }
        let view = { (body: String) in "import SwiftUI\n\nstruct ContentView: View {\n    @State private var query = \"\"\n\n    var body: some View {\n\(body)\n    }\n}\n" }
        try await commit("Initial project skeleton", by: 0, files: ["README.md": "# GitPico\n\nA calm native Git client.\n", "Sources/App/ContentView.swift": view("        Text(\"Hello\")"), ".gitignore": ".build/\n*.xcuserstate\n"])
        try await commit("Add repository model and parser", by: 1, files: ["Sources/Core/Repository.swift": "struct Repository {\n    let path: String\n}\n"])
        try await commit("Introduce sidebar navigation", by: 0, files: ["Sources/App/Sidebar.swift": "struct Sidebar {}\n"])
        try await git(["tag", "-a", "v0.1.0", "-m", "First preview"])
        try await git(["checkout", "-q", "-b", "feature/commit-graph"])
        try await commit("Draw commit graph lanes", by: 2, files: ["Sources/App/Graph.swift": "struct Graph { var lanes = 0 }\n"])
        try await commit("Color graph edges by lane", by: 2, files: ["Sources/App/Graph.swift": "struct Graph { var lanes = 0; var colors = 7 }\n"])
        try await git(["checkout", "-q", "main"])
        try await commit("Polish README wording", by: 1, files: ["README.md": "# GitPico\n\nA calm, native Git client for macOS.\n"])
        clock += 3_600
        try await git(["merge", "--no-ff", "-q", "-m", "Merge branch 'feature/commit-graph'", "feature/commit-graph"], author: people[0], date: clock)
        try await commit("Search across files and branches", by: 0, files: ["Sources/App/ContentView.swift": view("        VStack {\n            TextField(\"Search\", text: $query)\n            Text(\"Hello\")\n        }")])
        try await git(["checkout", "-q", "-b", "feature/stash-review"])
        try await commit("Preview stash contents before applying", by: 1, files: ["Sources/App/Stash.swift": "struct StashPreview {}\n"])
        try await git(["checkout", "-q", "-b", "fix/toolbar-overflow", "main"])
        try await commit("Keep toolbar items visible at 1080 points", by: 2, files: ["Sources/App/Toolbar.swift": "struct Toolbar {}\n"])
        try await git(["checkout", "-q", "main"])
        try await git(["tag", "v0.2.0"])
        try await git(["remote", "add", "origin", origin.path])
        try await git(["push", "-q", "-u", "origin", "main", "feature/commit-graph"])
        try await commit("Show sync status in the branch badge", by: 0, files: ["Sources/App/Badge.swift": "struct Badge { let ahead: Int; let behind: Int }\n"])
        try await commit("Group history rows by month", by: 1, files: ["Sources/App/History.swift": "struct History {}\n"])
        // Two saved stashes and a mixed working copy.
        try write("Sources/App/Sidebar.swift", "struct Sidebar {\n    var collapsed = false\n}\n")
        try await git(["stash", "push", "-q", "-m", "WIP sidebar collapse experiment"])
        try write("README.md", "# GitPico\n\nA calm, native Git client for macOS.\n\n## Draft\n")
        try await git(["stash", "push", "-q", "-m", "README draft section"])
        try write("Sources/App/ContentView.swift", view("        VStack(spacing: 12) {\n            TextField(\"Search\", text: $query)\n                .textFieldStyle(.roundedBorder)\n            Text(\"Hello, GitPico\")\n                .font(.title2)\n        }\n        .padding()"))
        try write("Sources/Core/Repository.swift", "struct Repository {\n    let path: String\n    var isBare = false\n}\n")
        try await git(["add", "Sources/Core/Repository.swift"])
        try write("README.md", "# GitPico\n\nA calm, native Git client for macOS.\n\nBuilt with SwiftUI.\n")
        try write("Sources/App/Composer.swift", "struct Composer {}\n")
        try FileManager.default.removeItem(at: url.appendingPathComponent("Sources/App/Badge.swift"))
        return url
    }
}
