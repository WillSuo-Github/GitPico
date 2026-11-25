import SwiftUI

/// Staggered rise-and-fade entrance parameters inspired by CostAware's
/// progressive offset + spring settle language, tuned for crisp macOS layouts.
struct StaggeredEntranceStyle: Equatable, Sendable {
    let baseOffset: CGFloat
    let offsetIncrement: CGFloat
    let scale: CGFloat
    let duration: Double
    let bounce: Double
    let delayIncrement: Double
    let maxIndex: Int

    /// Headers, action cards, and compact detail cards.
    static let card = Self(
        baseOffset: 12,
        offsetIncrement: 8,
        scale: 0.985,
        duration: 0.42,
        bounce: 0.08,
        delayIncrement: 0.035,
        maxIndex: 6
    )

    /// Full-width panes and AppKit-hosted containers (no horizontal scale distortion).
    static let pane = Self(
        baseOffset: 12,
        offsetIncrement: 8,
        scale: 1.0,
        duration: 0.42,
        bounce: 0.06,
        delayIncrement: 0.04,
        maxIndex: 4
    )

    /// Pure SwiftUI stacked disclosure rows (never used inside AppKit List cells).
    static let item = Self(
        baseOffset: 10,
        offsetIncrement: 4,
        scale: 0.99,
        duration: 0.38,
        bounce: 0.06,
        delayIncrement: 0.025,
        maxIndex: 8
    )
}

struct StaggeredEntranceModifier: ViewModifier {
    let isShowing: Bool
    let index: Int
    let style: StaggeredEntranceStyle
    let delayOverride: Double?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.repositoryStatusMotionEnabled) private var motionEnabled

    private var reduceMotion: Bool { systemReduceMotion || !motionEnabled }

    var isBypassed: Bool {
        reduceMotion
    }

    var effectiveIndex: Int {
        min(max(index, 0), style.maxIndex)
    }

    var yOffset: CGFloat {
        style.baseOffset + CGFloat(effectiveIndex) * style.offsetIncrement
    }

    var delay: Double {
        max(0, delayOverride ?? Double(effectiveIndex) * style.delayIncrement)
    }

    var animation: Animation? {
        guard !isBypassed else { return nil }
        return .spring(duration: style.duration, bounce: style.bounce).delay(delay)
    }

    func body(content: Content) -> some View {
        let visible = isBypassed || isShowing
        content
            .scaleEffect(visible ? 1 : style.scale)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : yOffset)
            .animation(visible ? animation : nil, value: visible)
    }
}

private struct StaggeredEntranceTriggerModifier<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    @Binding var isShowing: Bool
    let playOnInitialAppear: Bool
    let replayOnTriggerChange: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.repositoryStatusMotionEnabled) private var motionEnabled
    @State private var hasTriggered = false

    private var reduceMotion: Bool { systemReduceMotion || !motionEnabled }

    func body(content: Content) -> some View {
        content.task(id: trigger) {
            if reduceMotion {
                isShowing = true
                hasTriggered = true
                return
            }
            if !hasTriggered && !playOnInitialAppear {
                isShowing = true
                hasTriggered = true
                return
            }
            if hasTriggered && !replayOnTriggerChange {
                if !isShowing { isShowing = true }
                return
            }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { isShowing = false }
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
            hasTriggered = true
            isShowing = true
        }
    }
}

extension View {
    func staggeredEntrance(
        isShowing: Bool,
        index: Int,
        style: StaggeredEntranceStyle = .card,
        delay: Double? = nil
    ) -> some View {
        modifier(StaggeredEntranceModifier(isShowing: isShowing, index: index, style: style, delayOverride: delay))
    }

    func staggeredEntranceTrigger<Trigger: Equatable>(
        _ isShowing: Binding<Bool>,
        id trigger: Trigger,
        playOnAppear: Bool = true,
        replayOnChange: Bool = true
    ) -> some View {
        modifier(
            StaggeredEntranceTriggerModifier(
                trigger: trigger,
                isShowing: isShowing,
                playOnInitialAppear: playOnAppear,
                replayOnTriggerChange: replayOnChange
            )
        )
    }

    func staggeredEntranceTrigger(_ isShowing: Binding<Bool>) -> some View {
        staggeredEntranceTrigger(isShowing, id: 0, playOnAppear: true, replayOnChange: false)
    }
}
