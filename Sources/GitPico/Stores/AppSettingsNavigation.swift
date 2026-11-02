import Observation

enum AppSettingsTab: Hashable {
    case general, commits, aiCommits, externalTools, authentication, sshKeys, updates
}

/// Shared by the Settings scene and contextual entry points into a specific pane.
@MainActor @Observable final class AppSettingsNavigation {
    static let shared = AppSettingsNavigation()
    var selection: AppSettingsTab = .general
}
