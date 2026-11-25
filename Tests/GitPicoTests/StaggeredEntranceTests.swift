import AppKit
import SwiftUI
import Testing
@testable import GitPico

@Test @MainActor func staggeredEntranceComputesProgressiveOffsetDelayAndScrollCap() {
    let hero0 = StaggeredEntranceModifier(isShowing: false, index: 0, style: .hero)
    let hero3 = StaggeredEntranceModifier(isShowing: false, index: 3, style: .hero)
    let heroDeep = StaggeredEntranceModifier(isShowing: false, index: 20, style: .hero)

    #expect(hero0.yOffset == 20)
    #expect(hero3.yOffset == 80)
    #expect(heroDeep.yOffset == 140)
    #expect(hero0.delay == 0)
    #expect(abs(hero3.delay - 0.12) < 0.0001)
    #expect(!heroDeep.isBypassed)

    let section0 = StaggeredEntranceModifier(isShowing: false, index: 0, style: .section)
    let section2 = StaggeredEntranceModifier(isShowing: false, index: 2, style: .section)
    #expect(section2.yOffset > section0.yOffset)
    #expect(section2.delay > section0.delay)

    let negative = StaggeredEntranceModifier(isShowing: false, index: -5, style: .section)
    #expect(negative.effectiveIndex == 0)
    #expect(negative.yOffset == section0.yOffset)
    #expect(negative.delay == 0)

    let rowFirst = StaggeredEntranceModifier(isShowing: false, index: 0, style: .row)
    let rowTenth = StaggeredEntranceModifier(isShowing: false, index: 10, style: .row)
    let rowBeyondViewport = StaggeredEntranceModifier(isShowing: false, index: 11, style: .row)
    #expect(!rowFirst.isBypassed)
    #expect(!rowTenth.isBypassed)
    #expect(rowBeyondViewport.isBypassed)
    #expect(rowBeyondViewport.animation == nil)
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
