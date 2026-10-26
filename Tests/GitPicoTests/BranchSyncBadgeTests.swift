import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test @MainActor func currentBranchBadgeTracksFetchedUpstreamWithoutLeakingIntoPreviews() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let root = await f.repository.root
    func git(_ args: [String], at directory: URL? = nil) async throws {
        _ = try await GitProcess.run(args, at: directory ?? root)
    }
    func status() throws -> BranchSyncStatus {
        let snapshot = try #require(f.store.snapshot)
        let reference = try #require(snapshot.references.first { $0.isCurrent })
        return try #require(BranchSyncStatus.current(reference, snapshot: snapshot))
    }
    let untracked = try status()
    #expect(untracked.upstream.isEmpty && untracked.text == "HEAD")
    let origin = f.root.appendingPathComponent("BadgeOrigin.git"), peer = f.root.appendingPathComponent("BadgePeer")
    try await git(["init", "--bare", origin.path])
    try await git(["remote", "add", "origin", origin.path])
    try await git(["push", "-u", "origin", "main"])
    try await git(["clone", "--branch", "main", origin.path, peer.path], at: f.root)
    for (key, value) in [("user.name", "Badge Test"), ("user.email", "badge@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
        try await git(["config", key, value], at: peer)
    }
    for index in 1...2 { try await git(["commit", "--allow-empty", "-m", "Local \(index)"]) }
    try await f.sync()
    let outgoing = try status()
    #expect(outgoing.ahead == 2 && outgoing.behind == 0 && outgoing.text == "HEAD | ↑2")
    for index in 1...3 { try await git(["commit", "--allow-empty", "-m", "Remote \(index)"], at: peer) }
    try await git(["push", "origin", "main"], at: peer)
    // Changes not yet fetched cannot be counted from the local tracking ref.
    #expect(try status().behind == 0)
    f.store.sync(.fetch); await f.finish()
    #expect(f.store.error == nil)
    let diverged = try status()
    #expect(diverged.ahead == 2 && diverged.behind == 3 && diverged.text == "HEAD | ↑2 ↓3")
    let snapshot = try #require(f.store.snapshot), current = try #require(snapshot.references.first { $0.isCurrent })
    let other = try #require(snapshot.references.first { $0.isLocal && !$0.isCurrent })
    f.store.navigate(.reference(other.fullName)); await f.store.historyTask?.value; await f.store.detailTask?.value
    #expect(try status().text == "HEAD | ↑2 ↓3")
    #expect(BranchSyncStatus.current(other, snapshot: f.store.snapshot) == nil)
    try await git(["merge", "--no-edit", "origin/main"])
    try await f.sync()
    let merged = try status()
    #expect(merged.behind == 0 && merged.ahead == 3)
    f.store.sync(.push); await f.finish()
    let pushed = try status()
    #expect(f.store.error == nil && pushed.text == "HEAD")
    try await git(["pull", "--ff-only"], at: peer)
    try await git(["commit", "--allow-empty", "-m", "One more remote commit"], at: peer)
    try await git(["push", "origin", "main"], at: peer)
    f.store.sync(.fetch); await f.finish()
    #expect(try status().text == "HEAD | ↓1")
    f.store.sync(.pull)
    let pull = try #require(f.store.pullRequest)
    f.store.pullRequest = nil
    f.store.runPull(pull, policy: .fastForwardOnly); await f.finish()
    let pulled = try status()
    #expect(f.store.error == nil && pulled.text == "HEAD")
    try await git(["switch", "--detach"]); try await f.sync()
    #expect(BranchSyncStatus.current(current, snapshot: f.store.snapshot) == nil)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RENDER_COMPONENTS"] == "1", "Explicit offscreen component capture only."))
@MainActor func renderCurrentBranchSyncBadgesWithoutWindows() throws {
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_COMPONENT_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let cases: [BranchSyncStatus] = [
        .init(upstream: "origin/feature", ahead: 0, behind: 0),
        .init(upstream: "origin/feature", ahead: 3, behind: 0),
        .init(upstream: "origin/feature", ahead: 0, behind: 5),
        .init(upstream: "origin/feature", ahead: 3, behind: 5),
        .init(upstream: "origin/feature", ahead: 1234, behind: 5678),
        .init(upstream: "", ahead: 0, behind: 0)
    ]
    for scheme in [ColorScheme.light, .dark] {
        let content = VStack(spacing: 10) {
            ForEach(cases.indices, id: \.self) { index in
                HStack {
                    Image(systemName: "arrow.triangle.branch")
                    Text("feature").font(.system(size: 12, weight: .medium))
                    Spacer()
                    CurrentBranchBadge(status: cases[index])
                }
            }
        }.padding(12).frame(width: 280).background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content); renderer.scale = 2
        let image = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        try #require(image.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("branch-sync-\(scheme == .dark ? "dark" : "light").png"))
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
