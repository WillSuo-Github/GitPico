import AppKit
import SwiftUI
import Testing
@testable import GitPico

@Test(arguments: [false, true]) @MainActor
func pinnedBarsInsetTheContentsWithoutShrinkingTheViewport(useList: Bool) async throws {
    let insets = EdgeInsets(top: 44, leading: 0, bottom: 36, trailing: 0)
    var latest: ScrollGeometry?
    let fixture = PinnedScrollPane { measuredInsets in
        Group {
            if useList {
                List(0..<30, id: \.self) { index in Text(verbatim: "Row \(index)").frame(height: 24) }
                    .listStyle(.plain)
            } else {
                ScrollView {
                    LazyVStack {
                        ForEach(0..<30, id: \.self) { index in Text(verbatim: "Row \(index)").frame(height: 24) }
                    }
                }
            }
        }
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, newValue in latest = newValue }
        .pinnedScrollInsets(measuredInsets)
    } top: {
        Text(verbatim: "Upper controls").frame(height: insets.top)
    } bottom: {
        Text(verbatim: "Lower controls").frame(height: insets.bottom)
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 220), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: fixture)
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    for _ in 0..<40 {
        host.layoutSubtreeIfNeeded()
        if latest?.contentInsets == insets { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let geometry = try #require(latest)
    #expect(geometry.contentInsets.top == insets.top)
    #expect(geometry.contentInsets.bottom == insets.bottom)
    #expect(abs(geometry.visibleRect.height - 220) < 1)
    #expect(abs(geometry.visibleRect.minY + insets.top) < 1)
    #expect(!window.isVisible && !NSApp.isActive)
}
