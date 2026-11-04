import AppKit
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_CAPTURE_WORKFLOW_POLISH"] == "1", "Explicit windowless workflow capture only."))
@MainActor func renderWorkflowPolishWithoutActivation() async throws {
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_WORKFLOW_POLISH_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    await f.store.open(await f.repository.root)
    let commits = try await f.repository.snapshot().commits
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    defer { window.contentView = nil; window.close() }
    let patch = """
    diff --git a/View.swift b/View.swift
    --- a/View.swift
    +++ b/View.swift
    @@ -1,4 +1,4 @@
     import SwiftUI
    -let greeting = "Hello"
    +let greeting = "Hello, GitPico"
    -let count = 1
    +let count = 2
     // Review before committing
    """
    let panels: [(String, AnyView, NSSize)] = [
        ("diff", AnyView(ChunkDiffView(prepared: PreparedPatch.make(patch))), NSSize(width: 980, height: 500)),
        ("history-filters", AnyView(HistorySearchFilters(store: f.store)), NSSize(width: 550, height: 400)),
        ("batch", AnyView(BatchIntegrationSheet(store: f.store, request: BatchIntegrationRequest(action: .cherryPick, commits: commits))), NSSize(width: 660, height: 560)),
        ("cleanup", AnyView(BranchCleanupSheet(store: f.store, base: "refs/heads/main")), NSSize(width: 720, height: 580))
    ]
    for (name, content, size) in panels {
        window.setContentSize(size); window.contentView = NSHostingView(rootView: content)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(600))
            let view = try #require(window.contentView?.superview); view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
        }
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
