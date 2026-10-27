import AppKit
import Foundation
import Testing
@testable import GitPico

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
