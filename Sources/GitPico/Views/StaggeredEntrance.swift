import SwiftUI

/// Staggered rise-and-fade entrance parameters modeled after CostAware's
/// progressive offset + spring settle motion language, tuned for macOS views.
struct StaggeredEntranceStyle: Equatable, Sendable {
    let baseOffset: CGFloat
    let offsetIncrement: CGFloat
    let scale: CGFloat
    let duration: Double
    let bounce: Double
    let delayIncrement: Double
    let maxIndex: Int
    let skipBeyondMaxIndex: Bool

    static let hero = Self(
        baseOffset: 20,
        offsetIncrement: 20,
        scale: 0.94,
        duration: 0.52,
        bounce: 0.24,
        delayIncrement: 0.04,
        maxIndex: 6,
        skipBeyondMaxIndex: false
    )

    static let section = Self(
        baseOffset: 18,
        offsetIncrement: 14,
        scale: 0.96,
        duration: 0.48,
        bounce: 0.20,
        delayIncrement: 0.035,
        maxIndex: 8,
        skipBeyondMaxIndex: false
    )

    static let row = Self(
        baseOffset: 10,
        offsetIncrement: 3,
        scale: 0.985,
        duration: 0.40,
        bounce: 0.15,
        delayIncrement: 0.022,
        maxIndex: 10,
        skipBeyondMaxIndex: true
    )
}

struct StaggeredEntranceModifier: ViewModifier {
    let isShowing: Bool
    let index: Int
    let style: StaggeredEntranceStyle
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.repositoryStatusMotionEnabled) private var motionEnabled

    private var reduceMotion: Bool { systemReduceMotion || !motionEnabled }

    var isBypassed: Bool {
        reduceMotion || (style.skipBeyondMaxIndex && index > style.maxIndex)
    }

    var effectiveIndex: Int {
        min(max(index, 0), style.maxIndex)
    }

    var yOffset: CGFloat {
        style.baseOffset + CGFloat(effectiveIndex) * style.offsetIncrement
    }

    var delay: Double {
        Double(effectiveIndex) * style.delayIncrement
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
            if hasTriggered && !replayOnTriggerChange {
                if !isShowing { isShowing = true }
                return
            }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { isShowing = false }
            do {
                try await Task.sleep(for: .milliseconds(25))
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
        style: StaggeredEntranceStyle = .section
    ) -> some View {
        modifier(StaggeredEntranceModifier(isShowing: isShowing, index: index, style: style))
    }

    func staggeredEntranceTrigger<Trigger: Equatable>(
        _ isShowing: Binding<Bool>,
        id trigger: Trigger,
        replayOnChange: Bool = true
    ) -> some View {
        modifier(
            StaggeredEntranceTriggerModifier(
                trigger: trigger,
                isShowing: isShowing,
                replayOnTriggerChange: replayOnChange
            )
        )
    }

    func staggeredEntranceTrigger(_ isShowing: Binding<Bool>) -> some View {
        staggeredEntranceTrigger(isShowing, id: 0, replayOnChange: false)
    }
}
