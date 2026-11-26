import AppKit
import GitCore
import QuartzCore
import SwiftUI
import Testing
@testable import GitPico

@Test @MainActor func staggeredEntranceComputesProgressiveOffsetDelayAndScrollCap() {
    let card0 = StaggeredEntranceModifier(isShowing: false, index: 0, style: .card, delayOverride: nil)
    let card2 = StaggeredEntranceModifier(isShowing: false, index: 2, style: .card, delayOverride: nil)
    let cardDeep = StaggeredEntranceModifier(isShowing: false, index: 20, style: .card, delayOverride: nil)

    #expect(card0.yOffset == 12)
    #expect(card2.yOffset == 28)
    #expect(cardDeep.yOffset == 60)
    #expect(card0.delay == 0)
    #expect(abs(card2.delay - 0.07) < 0.0001)
    #expect(!cardDeep.isBypassed)

    let horizontalSibling = StaggeredEntranceModifier(isShowing: false, index: 1, style: .card, delayOverride: 0.08)
    let horizontalFirst = StaggeredEntranceModifier(isShowing: false, index: 1, style: .card, delayOverride: 0.03)
    #expect(horizontalSibling.yOffset == horizontalFirst.yOffset)
    #expect(horizontalSibling.delay > horizontalFirst.delay)

    let pane = StaggeredEntranceModifier(isShowing: false, index: 2, style: .pane, delayOverride: nil)
    #expect(pane.style.scale == 1.0)
    #expect(pane.yOffset == 28)

    let negative = StaggeredEntranceModifier(isShowing: false, index: -5, style: .card, delayOverride: nil)
    #expect(negative.effectiveIndex == 0)
    #expect(negative.yOffset == card0.yOffset)
    #expect(negative.delay == 0)

    // Items beyond maxIndex plateau cleanly instead of popping in ahead of earlier rows.
    let item8 = StaggeredEntranceModifier(isShowing: false, index: 8, style: .item, delayOverride: nil)
    let item15 = StaggeredEntranceModifier(isShowing: false, index: 15, style: .item, delayOverride: nil)
    #expect(!item15.isBypassed)
    #expect(item15.yOffset == item8.yOffset)
    #expect(item15.delay == item8.delay)
}

@Test @MainActor func staggeredEntranceTriggerEntersAfterInitialFrameAndSkipsWhenMotionDisabled() async throws {
    var enteredWithMotion = false
    let motionView = Color.clear
        .frame(width: 40, height: 40)
        .staggeredEntranceTrigger(Binding(get: { enteredWithMotion }, set: { enteredWithMotion = $0 }))

    let panel = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.contentView = NSHostingView(rootView: motionView)
    defer { panel.contentView = nil; panel.close() }
    panel.contentView?.layoutSubtreeIfNeeded()
    let motionDeadline = ContinuousClock.now + .seconds(2)
    while !enteredWithMotion && ContinuousClock.now < motionDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(enteredWithMotion)

    var enteredWithoutMotion = false
    let reducedView = Color.clear
        .frame(width: 40, height: 40)
        .staggeredEntranceTrigger(Binding(get: { enteredWithoutMotion }, set: { enteredWithoutMotion = $0 }))
        .environment(\.repositoryStatusMotionEnabled, false)
    panel.contentView = NSHostingView(rootView: reducedView)
    panel.contentView?.layoutSubtreeIfNeeded()
    let reducedDeadline = ContinuousClock.now + .seconds(2)
    while !enteredWithoutMotion && ContinuousClock.now < reducedDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(enteredWithoutMotion)
    #expect(!NSApplication.shared.isActive && NSApplication.shared.windows.filter(\.isVisible).isEmpty)
}

@MainActor private func findScrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView, scroll.documentView is HistoryTableView { return scroll }
    for subview in view.subviews {
        if let found = findScrollView(in: subview) { return found }
    }
    return nil
}

@MainActor private func graphicsHostLayer(for view: NSView) -> CALayer? {
    var layer: CALayer? = view.layer
    var current: NSView? = view
    var depth = 0
    while let node = current, depth < 6 {
        if String(describing: type(of: node)).contains("GraphicsView"), let backing = node.layer {
            return backing
        }
        current = node.superview
        depth += 1
    }
    while let candidate = layer {
        if candidate.opacity < 1 || candidate.bounds.origin.y != 0 { return candidate }
        layer = candidate.superlayer
    }
    return view.superview?.superview?.layer
}

@Test @MainActor func historyViewCommitTableAnimatesEntranceAndSettlesCleanly() async throws {
    let fixture = try await WorkingAppFixture.make()
    defer { fixture.clean() }
    let root = await fixture.repository.root
    _ = try await GitProcess.run(["branch", "entrance-branch"], at: root)
    try await fixture.sync()
    fixture.store.navigate(.history)
    let loadDeadline = ContinuousClock.now + .seconds(5)
    while fixture.store.visibleCommits.isEmpty && ContinuousClock.now < loadDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!fixture.store.visibleCommits.isEmpty)

    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 720, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: HistoryView(store: fixture.store))
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    host.layoutSubtreeIfNeeded()
    let scroll = try #require(findScrollView(in: host))
    let initialLayer = try #require(graphicsHostLayer(for: scroll))
    #expect(initialLayer.opacity < 1)

    var observedRise = false
    let settleDeadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < settleDeadline {
        host.layoutSubtreeIfNeeded()
        if let layer = graphicsHostLayer(for: scroll) {
            if layer.bounds.origin.y < -0.1 && layer.opacity > 0 && layer.opacity < 1 {
                observedRise = true
            }
            if layer.opacity >= 0.999 && abs(layer.bounds.origin.y) < 0.01 {
                break
            }
        }
        try await Task.sleep(for: .milliseconds(16))
    }
    let settledLayer = try #require(graphicsHostLayer(for: scroll))
    #expect(observedRise)
    #expect(settledLayer.opacity >= 0.999 && abs(settledLayer.bounds.origin.y) < 0.01)

    fixture.store.navigate(.reference("refs/heads/entrance-branch"))
    let branchDeadline = ContinuousClock.now + .seconds(5)
    while (fixture.store.visibleCommits.isEmpty || (graphicsHostLayer(for: scroll)?.opacity ?? 0) < 0.999) && ContinuousClock.now < branchDeadline {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
    }
    let branchLayer = try #require(graphicsHostLayer(for: scroll))
    #expect(branchLayer.opacity >= 0.999 && abs(branchLayer.bounds.origin.y) < 0.01)

    let reducedHost = NSHostingView(rootView: HistoryView(store: fixture.store).environment(\.repositoryStatusMotionEnabled, false))
    window.contentView = reducedHost
    reducedHost.layoutSubtreeIfNeeded()
    let reducedScroll = try #require(findScrollView(in: reducedHost))
    let reducedLayer = try #require(graphicsHostLayer(for: reducedScroll))
    #expect(reducedLayer.opacity >= 0.999 && abs(reducedLayer.bounds.origin.y) < 0.01)
    #expect(!NSApplication.shared.isActive && NSApplication.shared.windows.filter(\.isVisible).isEmpty)
}
