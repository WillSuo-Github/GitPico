import SwiftUI

extension EnvironmentValues {
    // Embedded views and previews can disable decorative motion without changing system preferences.
    @Entry var repositoryStatusMotionEnabled = true
}

struct RepositoryStatusBarBackground: View {
    let isRunning: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.repositoryStatusMotionEnabled) private var motionEnabled
    private var reduceMotion: Bool { systemReduceMotion || !motionEnabled }

    static func transition(isRunning: Bool, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: isRunning ? 0.2 : 0.3)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.bar)
            Color.accentColor.opacity(isRunning ? (colorScheme == .dark ? 0.1 : 0.06) : 0)
                .animation(Self.transition(isRunning: isRunning, reduceMotion: reduceMotion), value: isRunning)
        }
        .clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}
