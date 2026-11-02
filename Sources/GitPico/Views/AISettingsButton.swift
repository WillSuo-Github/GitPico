import SwiftUI

struct AISettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("AI Settings") {
            AppSettingsNavigation.shared.selection = .aiCommits
            openSettings()
        }
    }
}
