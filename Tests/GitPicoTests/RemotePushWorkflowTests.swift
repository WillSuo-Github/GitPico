import AppKit
import Foundation
import SwiftUI
import Testing
@testable import GitCore
@testable import GitPico

@Test @MainActor func directPushPreflightFailureNeverWritesTheServer() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let server = f.root.appendingPathComponent("Server.git")
    _ = try await GitProcess.run(["init", "--bare", server.path], at: f.root)
    try await f.repository.addRemote(name: "origin", fetchURLs: [server.path])
    let remote = try #require(try await f.repository.remoteConfigurations().first)
    let original = try #require(try await f.repository.references().first { $0.isCurrent })
    // A local ref that moved after the form was opened must not publish the old snapshot.
    _ = try await GitProcess.run(["commit", "--allow-empty", "-m", "Moved while form open"], at: f.repository.root)
    f.store.runRemotePush(remote: remote, source: original, destination: "refs/heads/published", setUpstream: true, pushURL: server.path)
    await f.finish()
    #expect(f.store.error != nil && !f.store.isBusy)
    #expect(try await GitProcess.run(["show-ref"], at: server, allowed: [0, 1]).data.isEmpty)
    #expect(try await GitProcess.run(["config", "--get", "branch." + original.name + ".remote"], at: f.repository.root, allowed: [0, 1]).data.isEmpty)
}

@Test @MainActor func directPushRejectsDivergenceAndWritesOnlyTheSelectedServer() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let first = f.root.appendingPathComponent("First.git"), second = f.root.appendingPathComponent("Second.git")
    for server in [first, second] { _ = try await GitProcess.run(["init", "--bare", server.path], at: f.root) }
    try await f.repository.addRemote(name: "origin", fetchURLs: [first.path], pushURLs: [first.path, second.path])
    let remote = try #require(try await f.repository.remoteConfigurations().first)
    let source = try #require(try await f.repository.references().first { $0.isCurrent })
    f.store.runRemotePush(remote: remote, source: source, destination: "refs/heads/published", setUpstream: false, pushURL: second.path)
    await f.finish()
    #expect(f.store.error == nil)
    #expect(try await GitProcess.run(["show-ref"], at: first, allowed: [0, 1]).data.isEmpty)
    #expect(try await GitProcess.run(["rev-parse", "refs/heads/published"], at: second).text.trimmingCharacters(in: .newlines) == source.hash)
    // Move only the server ahead, then attempt to push the older local tip again.
    _ = try await GitProcess.run(["commit", "--allow-empty", "-m", "Server advance"], at: f.repository.root)
    let next = try #require(try await f.repository.headPosition().hash)
    _ = try await GitProcess.run(["push", second.path, "HEAD:refs/heads/published"], at: f.repository.root)
    _ = try await GitProcess.run(["update-ref", source.fullName, source.hash, next], at: f.repository.root)
    f.store.runRemotePush(remote: remote, source: source, destination: "refs/heads/published", setUpstream: false, pushURL: second.path)
    await f.finish()
    #expect(f.store.error != nil)
    #expect(try await GitProcess.run(["rev-parse", "refs/heads/published"], at: second).text.trimmingCharacters(in: .newlines) == next)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_CAPTURE_PUSH_FLOW"] == "1", "Explicit offscreen Push flow captures."))
@MainActor func captureDirectPushFlowWithoutWindows() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_PUSH_FLOW_OUTPUT"]))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = "https://github.com/example/ClipboardMaster.git"
    try await f.repository.addRemote(name: "origin", fetchURLs: [url])
    f.store.managedRemotes = try await f.repository.remoteConfigurations()
    let source = try #require(f.store.snapshot?.references.first { $0.isCurrent })
    let remote = try #require(f.store.managedRemotes.first)
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.styleMask = [.borderless]; window.contentMinSize = .zero
    window.setFrame(NSRect(x: -10000, y: -10000, width: 460, height: 500), display: false)
    defer { window.contentView = nil; window.close() }
    for dark in [false, true] {
        try await capture(RemotePushSheet(store: f.store, source: source, remoteName: "origin", destination: nil, force: false), name: "01-publish", dark: dark)
        try await capture(RemotePushSheet(store: f.store, source: source, remoteName: "origin", destination: nil, force: true), name: "03-force-options", dark: dark)
        let preview = RemotePushPreview(remote: remote, source: source, destination: "refs/heads/main", remoteHash: source.hash, setUpstream: false, forceWithLease: true, pushURL: url)
        try await capture(RemotePushConfirmation(preview: preview, busy: false, back: {}, push: {}).frame(width: 460), name: "02-force-confirmation", dark: dark)
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)

    func capture<Content: View>(_ content: Content, name: String, dark: Bool) async throws {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: content.environment(\.controlActiveState, .key).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        try await Task.sleep(for: .milliseconds(300))
        window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + (dark ? "-dark" : "") + ".png"))
    }
}
