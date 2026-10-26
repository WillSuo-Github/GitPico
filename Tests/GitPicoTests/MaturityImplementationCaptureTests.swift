import AppKit
import Foundation
@testable import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_CAPTURE_MATURITY_IMPLEMENTATION"] == "1", "Explicit offscreen maturity feature capture only."))
@MainActor func renderMaturityImplementationWithoutActivation() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    await f.store.open(await f.repository.root)
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_MATURITY_IMPLEMENTATION_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    func png(_ color: NSColor) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        color.setFill(); NSRect(x: 0, y: 0, width: 200, height: 120).fill()
        NSColor.white.setFill(); NSRect(x: 30, y: 30, width: 90, height: 40).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    let root = await f.repository.root
    try png(.systemOrange).write(to: root.appendingPathComponent("Preview.png"))
    _ = try await GitProcess.run(["add", "--", "Preview.png"], at: root)
    try png(.systemBlue).write(to: root.appendingPathComponent("Preview.png"))
    let model = HostedReviewsModel(store: f.store)
    model.detail = HostedReview(number: 42, title: "Preserve workspace state between launches", body: "Restore repository tabs, native window groups and the last selected revision.\n\nChecks run in disposable repositories.", author: "pico-demo", source: "feature/session-restore", target: "main", head: String(repeating: "a", count: 40), state: "open", url: URL(string: "https://github.com/example/fixture/pull/42")!)
    model.checks = [HostedReviewCheck(id: "fixture-1", name: "macOS 26 / arm64", status: "success")]
    model.comments = [HostedReviewComment(id: 1, author: "reviewer", body: "Please keep missing repositories available for recovery.")]
    let snapshot = try #require(f.store.snapshot)
    let panels: [(String, AnyView, NSSize)] = [
        ("pull", AnyView(PullReviewSheet(store: f.store, request: PullReviewRequest(head: snapshot.head, upstream: "origin/main"))), NSSize(width: 580, height: 480)),
        ("binary-image", AnyView(BinaryComparisonView(repository: f.repository, path: "Preview.png", left: .index, right: .workingCopy)), NSSize(width: 1000, height: 620)),
        ("review-detail", AnyView(HostedReviewDetailView(model: model)), NSSize(width: 1000, height: 660)),
        ("updates", AnyView(UpdatesSettingsView(store: f.store)), NSSize(width: 740, height: 570))
    ]
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    defer { window.contentView = nil; window.close() }
    for (name, content, size) in panels {
        window.setContentSize(size); window.contentView = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(700))
            let view = try #require(window.contentView?.superview)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
        }
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
