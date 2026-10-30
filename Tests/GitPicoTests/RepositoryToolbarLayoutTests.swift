import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_FETCH_FEEDBACK_CAPTURE"] != nil, "Explicit hidden-window remote operation capture only."))
@MainActor func captureManualFetchFeedbackWithoutActivation() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let root = await f.repository.root
    let remote = f.root.appendingPathComponent("Remote.git")
    _ = try await GitProcess.run(["clone", "--bare", root.path, remote.path], at: f.root)
    _ = try await GitProcess.run(["remote", "add", "origin", remote.path], at: root)
    let upload = f.root.appendingPathComponent("delayed-upload-pack")
    try Data("#!/bin/sh\nsleep 2\nexec /usr/bin/git-upload-pack \"$@\"\n".utf8).write(to: upload)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: upload.path)
    _ = try await GitProcess.run(["config", "remote.origin.uploadpack", upload.path], at: root)
    let workspace = RepositoryWorkspace(library: f.store.library)
    await workspace.open(root)
    let windows = NativeRepositoryWindows(workspace: workspace, permitsPresentation: false)
    windows.start()
    defer { windows.stop(); workspace.shutdown() }
    let window = try #require(windows.window(for: workspace.selectedID))
    window.setFrame(NSRect(x: -10000, y: -10000, width: 1440, height: 900), display: false)
    window.appearance = NSAppearance(named: .aqua)
    let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_FETCH_FEEDBACK_CAPTURE"]))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func capture(_ name: String) throws {
        let view = try #require(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try #require(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
        let top = NSRect(x: view.bounds.minX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY - 110, width: view.bounds.width, height: 110)
        let topImage = try #require(view.bitmapImageRepForCachingDisplay(in: top))
        view.cacheDisplay(in: top, to: topImage)
        try #require(topImage.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + "-top.png"))
        let bottom = NSRect(x: view.bounds.minX, y: view.isFlipped ? view.bounds.maxY - 100 : view.bounds.minY, width: view.bounds.width, height: 100)
        let bottomImage = try #require(view.bitmapImageRepForCachingDisplay(in: bottom))
        view.cacheDisplay(in: bottom, to: bottomImage)
        try #require(bottomImage.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + "-bottom.png"))

    }
    func captureDetails(_ name: String, store: RepositoryStore) throws {
        let panel = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 220), styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: RepositoryActivityDetailsView(store: store).background(Color(nsColor: .windowBackgroundColor)))
        panel.contentView = hosting
        defer { panel.contentView = nil; panel.close() }
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 360, height: max(1, min(380, hosting.fittingSize.height))))
        hosting.layoutSubtreeIfNeeded()
        let image = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        try #require(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }
    try await Task.sleep(for: .milliseconds(350))
    try capture("01-idle")
    try captureDetails("01-idle-details", store: workspace.activeStore)
    workspace.activeStore.sync(.fetch)
    try await Task.sleep(for: .milliseconds(150))
    #expect(workspace.activeStore.isBusy)
    try capture("02-fetching")
    window.setFrame(NSRect(x: -10000, y: -10000, width: 1080, height: 900), display: false)
    try await Task.sleep(for: .milliseconds(150))
    try capture("02-fetching-narrow")
    window.appearance = NSAppearance(named: .darkAqua)
    try await Task.sleep(for: .milliseconds(150))
    try capture("02-fetching-dark")
    window.appearance = NSAppearance(named: .aqua)
    window.setFrame(NSRect(x: -10000, y: -10000, width: 1440, height: 900), display: false)
    await workspace.activeStore.operationTask?.value
    try await Task.sleep(for: .milliseconds(100))
    #expect(workspace.activeStore.error == nil && !workspace.activeStore.isBusy)
    try capture("03-completed")
    try captureDetails("03-completed-details", store: workspace.activeStore)
    let completedID = workspace.activeStore.operationFeedback?.id
    try await Task.sleep(for: .milliseconds(2300))
    #expect(workspace.activeStore.operationFeedback?.id == completedID && workspace.activeStore.operationFeedback?.isVisible == false)
    try capture("03-settled")
    try captureDetails("03-settled-details", store: workspace.activeStore)

    _ = try await GitProcess.run(["branch", "--set-upstream-to", "origin/main", "main"], at: root)
    workspace.activeStore.refresh(); await workspace.activeStore.operationTask?.value
    workspace.activeStore.reviewPull()
    let pull = try #require(workspace.activeStore.pullRequest)
    workspace.activeStore.pullRequest = nil
    workspace.activeStore.runPull(pull, policy: .merge)
    try await Task.sleep(for: .milliseconds(150))
    #expect(workspace.activeStore.operationFeedback?.command == .pull && workspace.activeStore.isBusy)
    try capture("04-pulling")
    window.setFrame(NSRect(x: -10000, y: -10000, width: 1080, height: 900), display: false)
    window.appearance = NSAppearance(named: .darkAqua)
    try await Task.sleep(for: .milliseconds(150))
    try capture("04-pulling-dark-narrow")
    await workspace.activeStore.operationTask?.value
    try await Task.sleep(for: .milliseconds(100))
    try capture("05-pull-completed")

    _ = try await GitProcess.run(["commit", "--allow-empty", "-m", "Push feedback capture"], at: root)
    let hooks = f.root.appendingPathComponent("Hooks")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    let hook = hooks.appendingPathComponent("pre-push")
    try Data("#!/bin/sh\nsleep 2\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    _ = try await GitProcess.run(["config", "core.hooksPath", hooks.path], at: root)
    workspace.activeStore.refresh(); await workspace.activeStore.operationTask?.value
    window.appearance = NSAppearance(named: .aqua)
    window.setFrame(NSRect(x: -10000, y: -10000, width: 1440, height: 900), display: false)
    workspace.activeStore.sync(.push)
    try await Task.sleep(for: .milliseconds(150))
    #expect(workspace.activeStore.operationFeedback?.command == .push && workspace.activeStore.isBusy)
    try capture("06-pushing")
    window.setFrame(NSRect(x: -10000, y: -10000, width: 1080, height: 900), display: false)
    window.appearance = NSAppearance(named: .darkAqua)
    try await Task.sleep(for: .milliseconds(150))
    try capture("06-pushing-dark-narrow")
    await workspace.activeStore.operationTask?.value
    try await Task.sleep(for: .milliseconds(100))
    try capture("07-push-completed")
    #expect(workspace.activeStore.error == nil)

    // The consolidated entry must still expose network history after manual feedback is cleared.
    workspace.activeStore.clearOperationFeedback()
    await workspace.activeStore.fetchInBackground()
    #expect(workspace.activeStore.operationFeedback == nil)
    try captureDetails("07-network-history-details", store: workspace.activeStore)

    // Render a real failure's details without a root ContentView, whose system alert can reveal a hidden window.
    let failed = try await WorkingAppFixture.make(); defer { failed.clean(); failed.store.disconnectNetworkContext() }
    let failedRoot = await failed.repository.root
    _ = try await GitProcess.run(["remote", "add", "origin", failed.root.appendingPathComponent("Missing.git").path], at: failedRoot)
    await failed.store.openInPlace(failedRoot)
    failed.store.sync(.fetch); await failed.store.operationTask?.value
    #expect(failed.store.operationFeedback?.phase == .failed && failed.store.operationFeedback?.isVisible == true)
    try captureDetails("08-failed-details", store: failed.store)

    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func repositoryToolbarKeepsCenterEmptyAndTrailingToolsRightAlignedWithoutActivation() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let workspace = RepositoryWorkspace(library: f.store.library)
    await workspace.open(await f.repository.root)
    let windows = NativeRepositoryWindows(workspace: workspace, permitsPresentation: false)
    windows.start()
    defer { windows.stop(); workspace.shutdown() }
    let window = try #require(windows.window(for: workspace.selectedID))
    for width: CGFloat in [1080, 1440] {
        window.setFrame(NSRect(x: -10000, y: -10000, width: width, height: 900), display: false)
        try await Task.sleep(for: .milliseconds(400))
        let view = try #require(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        let toolbar = try #require(window.toolbar)
        #expect(!toolbar.items.contains { $0.itemIdentifier.rawValue.contains("repository.branch") })
        let search = try #require(toolbar.items.first { $0.itemIdentifier.rawValue.contains("repository.search") }?.view)
        let searchRect = search.convert(search.bounds, to: nil)
        if width == 1440 { #expect(searchRect.maxX > width - 60 && searchRect.midX > width * 0.75) }
        if let path = ProcessInfo.processInfo.environment["GITPICO_TOOLBAR_LAYOUT_CAPTURE"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            try #require(image.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("repository-toolbar-\(Int(width)).png"))
            let barRect = NSRect(x: view.bounds.minX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY - 64, width: view.bounds.width, height: 64)
            let bar = try #require(view.bitmapImageRepForCachingDisplay(in: barRect))
            view.cacheDisplay(in: barRect, to: bar)
            try #require(bar.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("repository-toolbar-\(Int(width))-bar.png"))
            let frames = toolbar.items.map { ["id": $0.itemIdentifier.rawValue, "label": $0.label, "frame": $0.view.map { NSStringFromRect($0.convert($0.bounds, to: nil)) } ?? ""] }
            try JSONSerialization.data(withJSONObject: frames, options: [.sortedKeys, .prettyPrinted]).write(to: folder.appendingPathComponent("repository-toolbar-\(Int(width)).json"))
        }
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
