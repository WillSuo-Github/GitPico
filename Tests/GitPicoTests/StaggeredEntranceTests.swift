import AppKit
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
