import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_CAPTURE_MATURITY_PANELS"] == "1", "Explicit suppressed settings/activity/draft capture only."))
@MainActor func renderMaturityPanelsWithoutActivation() async throws {
    let f = try await PreviewFixture.make(); defer { f.clean() }
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_MATURITY_CAPTURE_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    // Metadata-only account fixture. No real Keychain credential or API request is used.
    let profile = AuthenticationProfile(id: UUID(), provider: .github, host: "github.com", username: "pico-demo", method: ProcessInfo.processInfo.environment["GITPICO_CAPTURE_OAUTH_PANELS"] == "1" ? .oauth : nil)
    let profileObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
    let document: [String: Any] = ["profiles":[profileObject], "assignments":[(await f.repository.root).path:profile.id.uuidString]]
    try JSONSerialization.data(withJSONObject: document).write(to: f.store.authentication.file)
    f.store.authentication.reload()
    let cancellation = GitNetworkCancellation()
    f.store.networkActivity?.receive(GitNetworkEvent(id: UUID(), command: "fetch", repository: "GitPico", started: Date().addingTimeInterval(-120), phase: .succeeded, output: "Receiving objects: 100% (42/42), done.\nRemote-tracking branches updated.", cancellation: cancellation))
    f.store.networkActivity?.receive(GitNetworkEvent(id: UUID(), command: "push", repository: "GitPico", started: Date().addingTimeInterval(-30), phase: .failed, output: "Authentication failed. Check the selected account and repository permissions.", cancellation: cancellation))
    let conflict = try await DesignGalleryFixture.makeConflict(in: f.root)
    let conflictRepository = try await GitRepository.open(conflict)
    await f.store.open(conflict)
    let snapshot = try await conflictRepository.conflict("Sources/App/Theme.swift")
    f.store.conflictDrafts[snapshot.path] = ConflictDraft(snapshot: snapshot, text: "import SwiftUI\n\nenum Theme {\n    static let accent = Color.orange\n    static let corner: CGFloat = 10\n}\n")
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    defer { window.contentView = nil; window.close() }
    let panels: [(String, AnyView, NSSize)] = [
        ("authentication", AnyView(AuthenticationPanel(store: f.store)), NSSize(width: 740, height: 700)),
        ("network", AnyView(NetworkActivityView(store: f.store)), NSSize(width: 820, height: 620)),
        ("conflict-drafts", AnyView(ConflictDraftsSheet(store: f.store)), NSSize(width: 760, height: 580))
    ]
    for (name, content, size) in panels {
        window.setContentSize(size)
        window.contentView = NSHostingView(rootView: content)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(400))
            let view = try #require(window.contentView?.superview)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
            if name == "authentication", ProcessInfo.processInfo.environment["GITPICO_CAPTURE_OAUTH_PANELS"] == "1" {
                func scrollingForm(_ view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView, let document = scroll.documentView, document.bounds.height > scroll.contentView.bounds.height + 20 { return scroll }
                    return view.subviews.lazy.compactMap { scrollingForm($0) }.first
                }
                if let scroll = scrollingForm(view), let document = scroll.documentView {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(for: .milliseconds(150))
                    let lower = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: lower)
                    try #require(lower.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("authentication-lower-" + (dark ? "dark.png" : "light.png")))
                    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
