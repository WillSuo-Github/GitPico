import SwiftUI

extension EnvironmentValues {
    // Embedded views and previews can disable decorative motion without changing system preferences.
    @Entry var repositoryStatusMotionEnabled = true
}

struct RepositoryStatusBarBackground: View {
    static let featherHeight: CGFloat = 8

    let isRunning: Bool
    var featherHeight: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.repositoryStatusMotionEnabled) private var motionEnabled
    private var reduceMotion: Bool { systemReduceMotion || !motionEnabled }

    static func transition(isRunning: Bool, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: isRunning ? 0.2 : 0.3)
    }

    var body: some View {
        let backdrop = ScrollBarBackdrop(
            edge: .bottom,
            tint: Color.accentColor.opacity(isRunning ? (colorScheme == .dark ? 0.1 : 0.06) : 0)
        )
        .animation(Self.transition(isRunning: isRunning, reduceMotion: reduceMotion), value: isRunning)

        if reduceTransparency, featherHeight > 0 {
            VStack(spacing: 0) {
                Color.clear.frame(height: featherHeight)
                backdrop
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            backdrop
        }
    }
}
