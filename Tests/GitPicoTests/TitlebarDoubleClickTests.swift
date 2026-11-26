import AppKit
import Foundation
import GitCore
import ObjectiveC
import SwiftUI
import Testing
@testable import GitPico

@MainActor private func findSubview(in root: NSView, named className: String) -> NSView? {
    if String(describing: type(of: root)) == className { return root }
    for subview in root.subviews {
        if let match = findSubview(in: subview, named: className) { return match }
    }
    return nil
}

@MainActor private func titlebarDoubleClickAccepted(
    in window: NSWindow,
    themeFrame: NSView,
    titlebarContainer: NSView,
    at point: NSPoint
) throws -> (hitInTitlebar: Bool, accepted: Bool) {
    let hitView = themeFrame.hitTest(point)
    let hitInTitlebar = hitView?.isDescendant(of: titlebarContainer) ?? false
    let event = try #require(
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
    )
    let themeRecognizer = try #require(
        themeFrame.gestureRecognizers.first { $0.action == NSSelectorFromString("_handleTitledFrameDoubleClickGesture:") }
    )
    let containerRecognizer = try #require(
        titlebarContainer.gestureRecognizers.first { $0.action == NSSelectorFromString("_handleTitlebarContainerDoubleClickGesture:") }
    )
    let themeAttempts = themeRecognizer.delegate?.gestureRecognizer?(themeRecognizer, shouldAttemptToRecognizeWith: event) ?? false
    let containerAttempts = hitInTitlebar && (containerRecognizer.delegate?.gestureRecognizer?(containerRecognizer, shouldAttemptToRecognizeWith: event) ?? false)
    return (hitInTitlebar, themeAttempts || containerAttempts)
}

@Test @MainActor func transparentTitlebarAcceptsDoubleClickInEmptyToolbarAndExcludesControls() async throws {
    let testFrame = NSRect(x: -10000, y: -10000, width: 1200, height: 740)

    let fixture = try await WorkingAppFixture.make(); defer { fixture.clean() }
    let workspace = RepositoryWorkspace(library: fixture.store.library)
    await workspace.open(await fixture.repository.root)
    let windows = NativeRepositoryWindows(workspace: workspace, permitsPresentation: false)
    windows.start()
    defer { windows.stop(); workspace.shutdown() }

    let repoWindow = try #require(windows.window(for: workspace.selectedID))
    repoWindow.setFrame(testFrame, display: false)
    try await Task.sleep(for: .milliseconds(350))
    let repoTheme = try #require(repoWindow.contentView?.superview)
    repoTheme.layoutSubtreeIfNeeded()
    let repoTitlebar = try #require(findSubview(in: repoTheme, named: "NSTitlebarContainerView"))

    #expect(repoWindow.titlebarAppearsTransparent)
    #expect(repoWindow.usesNativeTransparentTitlebarDoubleClick)

    for emptyPoint in [
        NSPoint(x: 130, y: repoWindow.frame.height - 26),
        NSPoint(x: 470, y: repoWindow.frame.height - 26),
        NSPoint(x: 600, y: repoWindow.frame.height - 26),
        NSPoint(x: 600, y: repoWindow.frame.height - 8),
        NSPoint(x: 600, y: repoWindow.contentLayoutRect.maxY + 4),
    ] {
        let result = try titlebarDoubleClickAccepted(in: repoWindow, themeFrame: repoTheme, titlebarContainer: repoTitlebar, at: emptyPoint)
        #expect(result.hitInTitlebar)
        #expect(result.accepted)
    }

    for excludedPoint in [
        NSPoint(x: 26, y: repoWindow.frame.height - 26),
        NSPoint(x: 72, y: repoWindow.frame.height - 26),
        NSPoint(x: 210, y: repoWindow.frame.height - 26),
        NSPoint(x: 279, y: repoWindow.frame.height - 26),
        NSPoint(x: 305, y: repoWindow.frame.height - 26),
        NSPoint(x: 768, y: repoWindow.frame.height - 26),
        NSPoint(x: 900, y: repoWindow.frame.height - 26),
        NSPoint(x: 1050, y: repoWindow.frame.height - 26),
        NSPoint(x: 600, y: repoWindow.contentLayoutRect.maxY - 6),
    ] {
        let result = try titlebarDoubleClickAccepted(in: repoWindow, themeFrame: repoTheme, titlebarContainer: repoTitlebar, at: excludedPoint)
        #expect(!result.accepted)
    }

    workspace.activeStore.fetchFeedback = RepositoryOperationFeedback(
        command: .fetch,
        repository: await fixture.repository.root.path,
        activity: "Fetching origin…",
        phase: .running,
        isVisible: true
    )
    try await Task.sleep(for: .milliseconds(200))
    repoTheme.layoutSubtreeIfNeeded()
    let centerView = try #require(
        repoWindow.toolbar?.items.first(where: { $0.itemIdentifier.rawValue.contains("repository.centerSpacing") })?.view
    )
    let capsuleRect = centerView.convert(centerView.bounds, to: nil)
    let capsuleResult = try titlebarDoubleClickAccepted(
        in: repoWindow,
        themeFrame: repoTheme,
        titlebarContainer: repoTitlebar,
        at: NSPoint(x: capsuleRect.midX, y: capsuleRect.midY)
    )
    #expect(!capsuleResult.accepted)
    workspace.activeStore.clearOperationFeedback()

    workspace.newTab(from: workspace.selectedID)
    try await Task.sleep(for: .milliseconds(350))
    let pickerWindow = try #require(windows.window(for: workspace.selectedID))
    pickerWindow.setFrame(testFrame, display: false)
    let pickerTheme = try #require(pickerWindow.contentView?.superview)
    pickerTheme.layoutSubtreeIfNeeded()
    let pickerTitlebar = try #require(findSubview(in: pickerTheme, named: "NSTitlebarContainerView"))

    #expect(pickerWindow.titlebarAppearsTransparent)
    #expect(pickerWindow.usesNativeTransparentTitlebarDoubleClick)

    let pickerEmpty = try titlebarDoubleClickAccepted(
        in: pickerWindow,
        themeFrame: pickerTheme,
        titlebarContainer: pickerTitlebar,
        at: NSPoint(x: 600, y: pickerWindow.frame.height - 26)
    )
    #expect(pickerEmpty.hitInTitlebar)
    #expect(pickerEmpty.accepted)

    let pickerTabBar = try titlebarDoubleClickAccepted(
        in: pickerWindow,
        themeFrame: pickerTheme,
        titlebarContainer: pickerTitlebar,
        at: NSPoint(x: 600, y: pickerWindow.contentLayoutRect.maxY + 14)
    )
    #expect(!pickerTabBar.accepted)

    let pickerBelow = try titlebarDoubleClickAccepted(
        in: pickerWindow,
        themeFrame: pickerTheme,
        titlebarContainer: pickerTitlebar,
        at: NSPoint(x: 600, y: pickerWindow.contentLayoutRect.maxY - 10)
    )
    #expect(!pickerBelow.accepted)

    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func fallbackTitlebarDoubleClickActionRespectsSystemPreference() throws {
    let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1728, height: 1080)
    let initialFrame = NSRect(x: visibleFrame.minX + 100, y: visibleFrame.minY + 100, width: 1200, height: 740)
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    defer { window.close() }
    window.setFrame(initialFrame, display: false)

    window.performFallbackTitlebarDoubleClickAction(preference: "None")
    #expect(window.frame == initialFrame)

    window.performFallbackTitlebarDoubleClickAction(preference: "Fill")
    #expect(window.isZoomed)
    #expect(window.frame.size == visibleFrame.size)

    window.performFallbackTitlebarDoubleClickAction(preference: "Maximize")
    #expect(!window.isZoomed)
    #expect(window.frame == initialFrame)

    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
