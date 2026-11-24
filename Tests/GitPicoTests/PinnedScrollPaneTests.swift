import AppKit
import SwiftUI
import Testing
@testable import GitPico

@Test(arguments: [false, true], [false, true]) @MainActor
func pinnedBarsInsetTheContentsWithoutShrinkingTheViewport(useList: Bool, floatingBottom: Bool) async throws {
    let statusBarHeight = RepositoryStatusBar.height
    let footerHeight: CGFloat = 36
    let insets = EdgeInsets(top: 44, leading: 0, bottom: footerHeight + statusBarHeight, trailing: 0)
    var latest: ScrollGeometry?
    var footerFrame: CGRect?
    let fixture = PinnedScrollPane(bottomIsFloating: floatingBottom) { measuredInsets in
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
        Text(verbatim: "Lower controls").frame(height: footerHeight)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("fixture")) }) { footerFrame = $0 }
    }
    .environment(\.repositoryStatusBarInset, statusBarHeight)
    .coordinateSpace(.named("fixture"))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 220), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: fixture)
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    for _ in 0..<40 {
        host.layoutSubtreeIfNeeded()
        if latest?.contentInsets == insets, footerFrame != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let geometry = try #require(latest)
    #expect(geometry.contentInsets.top == insets.top)
    #expect(geometry.contentInsets.bottom == insets.bottom)
    #expect(abs(geometry.visibleRect.height - 220) < 1)
    #expect(abs(geometry.visibleRect.minY + insets.top) < 1)
    let footer = try #require(footerFrame)
    #expect(abs(footer.maxY - (220 - statusBarHeight)) < 1)
    #expect(!window.isVisible && !NSApp.isActive)
}

@Test(
    .enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency, "Requires transparent materials."),
    arguments: [VerticalEdge.top, .bottom], [ColorScheme.light, .dark]
) @MainActor
func scrollBarBackdropFadesAcrossTheBarWithoutExtendingPastIt(edge: VerticalEdge, scheme: ColorScheme) throws {
    let backdrop = HStack(spacing: 0) {
        VStack(spacing: 0) {
            Color.clear.frame(height: 16)
            Color.clear.frame(height: 80).background { ScrollBarBackdrop(edge: edge) }
            Color.clear.frame(height: 16)
        }
        .frame(width: 24)
        .background(.blue)
        Color.clear.frame(width: 8, height: 112).background(.windowBackground).background(.background)
    }
    .environment(\.colorScheme, scheme)
    let bitmap = try renderHostedBitmap(backdrop, size: CGSize(width: 32, height: 112), scale: 1, scheme: scheme)

    func pixel(at y: Int, x: Int = 12) throws -> NSColor {
        try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
    }

    let surface = try pixel(at: 55, x: 28)
    let content = try pixel(at: 8)
    let outer = try pixel(at: edge == .top ? 17 : 94)
    let behindControls = try pixel(at: edge == .top ? 56 : 55)
    let transition = try pixel(at: edge == .top ? 74 : 38)
    let inner = try pixel(at: edge == .top ? 95 : 16)
    #expect(difference(outer, surface) > 0.05)
    #expect(difference(outer, surface) < 0.16)
    #expect(difference(outer, content) > 0.70)
    #expect(difference(behindControls, surface) > 0.075)
    #expect(difference(behindControls, content) > 0.20)
    #expect(difference(transition, surface) > 0.12)
    #expect(difference(transition, content) > 0.10)
    #expect(difference(inner, content) < 0.07)
    #expect(try difference(pixel(at: 99), content) < 0.01)
}

@Test @MainActor
func variableBlurViewConfiguresProgressiveBackdropLayer() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
    window.contentView = container
    defer { window.contentView = nil; window.close() }

    let blurView = VariableBlurNSView(maxBlurRadius: 10, direction: .blurredBottomClearTop, transitionHeight: 28)
    blurView.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
    container.addSubview(blurView)
    blurView.layoutSubtreeIfNeeded()

    #expect(blurView.isFlipped)
    #expect(!blurView.isOpaque)
    #expect(blurView.hitTest(NSPoint(x: 12, y: 12)) == nil)
    #expect(blurView.isUsingVariableBlurBackdrop)
    let backdrop = try #require(blurView.layer?.sublayers?.first { NSStringFromClass(type(of: $0)) == "CABackdropLayer" })
    #expect(!backdrop.isHidden)
    #expect((backdrop.filters?.count ?? 0) == 1)

    blurView.frame = NSRect(x: 0, y: 0, width: 420, height: 28)
    blurView.layoutSubtreeIfNeeded()
    #expect(backdrop.frame == NSRect(x: 0, y: 0, width: 420, height: 28))
    #expect(!backdrop.isHidden)
    #expect((backdrop.filters?.count ?? 0) == 1)

    blurView.frame = .zero
    blurView.layoutSubtreeIfNeeded()
    #expect(backdrop.isHidden)
    #expect(!window.isVisible && !NSApp.isActive)
}

@Test(
    .enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency, "Requires transparent materials."),
    arguments: [VerticalEdge.top, .bottom], [ColorScheme.light, .dark]
) @MainActor
func scrollBarBackdropKeepsAUniformWindowSurface(edge: VerticalEdge, scheme: ColorScheme) throws {
    let surface = Color.clear.frame(width: 48, height: 86)
        .overlay(alignment: edge == .top ? .top : .bottom) {
            ScrollBarBackdrop(edge: edge).frame(height: edge == .top ? Pico.headerHeight : RepositoryStatusBar.height)
        }
        .background(.windowBackground)
        .background(.background)
        .environment(\.colorScheme, scheme)
    let bitmap = try renderHostedBitmap(surface, size: CGSize(width: 48, height: 86), scale: 2, scheme: scheme)
    let x = bitmap.pixelsWide / 2
    let referenceY = edge == .top ? bitmap.pixelsHigh - 2 : 1
    let reference = try #require(bitmap.colorAt(x: x, y: referenceY)?.usingColorSpace(.sRGB))
    var largestDelta: CGFloat = 0
    for y in 0..<bitmap.pixelsHigh {
        let actual = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        largestDelta = max(largestDelta,
                           abs(actual.redComponent - reference.redComponent),
                           abs(actual.greenComponent - reference.greenComponent),
                           abs(actual.blueComponent - reference.blueComponent))
    }
    #expect(largestDelta <= 1.0 / 255)
}

@Test(
    .enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency, "Requires transparent materials."),
    arguments: [VerticalEdge.top, .bottom], [ColorScheme.light, .dark]
) @MainActor
func scrollBarBackdropWithoutWindowSurfaceOmitsOpaqueTint(edge: VerticalEdge, scheme: ColorScheme) throws {
    let surface = Color.blue.frame(width: 32, height: 64)
        .overlay(alignment: edge == .top ? .top : .bottom) {
            ScrollBarBackdrop(edge: edge, showsWindowSurface: false).frame(height: 44)
        }
        .environment(\.colorScheme, scheme)
    let bitmap = try renderHostedBitmap(surface, size: CGSize(width: 32, height: 64), scale: 1, scheme: scheme)
    let column = bitmap.pixelsWide / 2
    let uncoveredRow = edge == .top ? bitmap.pixelsHigh - 2 : 1
    let coveredRow = edge == .top ? 12 : bitmap.pixelsHigh - 13
    let uncovered = try #require(bitmap.colorAt(x: column, y: uncoveredRow)?.usingColorSpace(.sRGB))
    let covered = try #require(bitmap.colorAt(x: column, y: coveredRow)?.usingColorSpace(.sRGB))
    let delta = max(
        abs(covered.redComponent - uncovered.redComponent),
        abs(covered.greenComponent - uncovered.greenComponent),
        abs(covered.blueComponent - uncovered.blueComponent)
    )
    #expect(delta <= 1.0 / 255)
}

@MainActor
private func renderHostedBitmap<Content: View>(_ content: Content, size: CGSize, scale: Int, scheme: ColorScheme) throws -> NSBitmapImageRep {
    let rect = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
    host.frame = rect
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    host.layoutSubtreeIfNeeded()

    let pixelsWide = Int(size.width) * scale
    let pixelsHigh = Int(size.height) * scale
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ))
    bitmap.size = size
    host.cacheDisplay(in: rect, to: bitmap)
    #expect(!window.isVisible && !NSApp.isActive)
    return bitmap
}
