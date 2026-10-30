import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_STATUS_MOTION_CAPTURE"] != nil, "Explicit hidden-window status motion capture only."))
@MainActor func captureStatusBarMotionWithoutActivation() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let root = await f.repository.root
    let remote = f.root.appendingPathComponent("Remote.git")
    _ = try await GitProcess.run(["clone", "--bare", root.path, remote.path], at: f.root)
    _ = try await GitProcess.run(["remote", "add", "origin", remote.path], at: root)
    let upload = f.root.appendingPathComponent("motion-upload-pack")
    try Data("#!/bin/sh\nsleep 3\nexec /usr/bin/git-upload-pack \"$@\"\n".utf8).write(to: upload)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: upload.path)
    _ = try await GitProcess.run(["config", "remote.origin.uploadpack", upload.path], at: root)
    let workspace = RepositoryWorkspace(library: f.store.library)
    await workspace.open(root)
    let windows = NativeRepositoryWindows(workspace: workspace, permitsPresentation: false)
    windows.start()
    defer { windows.stop(); workspace.shutdown() }
    let window = try #require(windows.window(for: workspace.selectedID))
    let reduced = ProcessInfo.processInfo.environment["GITPICO_STATUS_MOTION_REDUCED"] == "1"
    window.contentView = NSHostingView(rootView: RepositoryWorkspaceView(workspace: workspace).environment(\.repositoryStatusMotionEnabled, !reduced))
    window.appearance = NSAppearance(named: .aqua)
    window.setFrame(NSRect(x: -10000, y: -10000, width: 1080, height: 900), display: false)
    let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_STATUS_MOTION_CAPTURE"]))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try await Task.sleep(for: .milliseconds(350))
    let start = ContinuousClock.now
    var completed: ContinuousClock.Instant?
    var began = false
    var frames: [[String: Any]] = []
    while start.duration(to: .now) < .seconds(12) {
        let elapsed = start.duration(to: .now)
        if elapsed >= .milliseconds(400), !began { began = true; workspace.activeStore.sync(.fetch) }
        if began, !workspace.activeStore.isBusy, completed == nil { completed = .now }
        let view = try #require(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        let rect = NSRect(x: view.bounds.minX, y: view.isFlipped ? view.bounds.maxY - 60 : view.bounds.minY, width: view.bounds.width, height: 60)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        let name = String(format: "frame-%04d.png", frames.count)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name))
        frames.append(["file": name, "seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, "isBusy": workspace.activeStore.isBusy, "reduceMotion": reduced])
        if let completed, completed.duration(to: .now) > .milliseconds(2600) { break }
        try await Task.sleep(for: .milliseconds(70))
    }
    await workspace.activeStore.operationTask?.value
    #expect(workspace.activeStore.error == nil && !workspace.activeStore.isBusy)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
    try JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("frames.json"))
}
