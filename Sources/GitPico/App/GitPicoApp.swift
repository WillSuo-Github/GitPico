import AppKit
import GitCore
import SwiftUI

struct GitPicoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = RepositoryStore()

    var body: some Scene {
        Window("GitPico", id: "main") {
            ContentView(store: store)
                .task { await store.startup() }
        }
        .defaultSize(width: 1420, height: 900)
        .windowToolbarStyle(.unifiedCompact)
        .commands { RepositoryCommands(store: store) }
        Settings { SettingsView(tools: store.toolPreferences) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct SettingsView: View {
    let tools: ExternalToolPreferences
    @State private var preferences = AppPreferences.shared
    var body: some View {
        TabView {
        Form {
            LabeledContent("Application", value: "GitPico · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.01")")
            LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Development")
            Toggle("Always offer to stash local changes", isOn: $preferences.offerAutomaticStash)
            LabeledContent("Platform", value: "macOS 26 or later")
            if let error = preferences.lastSaveError { Text(error).foregroundStyle(.red).font(.caption) }
            Slider(value: $preferences.diffFontSize, in: 10...18, step: 1) { Text("Diff font size") }
            Text("Uses your system Git identity, SSH agent, signing, and repository configuration. Configure credentials with Git before synchronizing.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .tabItem { Label("General", systemImage: "gearshape") }
        ExternalToolSettingsView(preferences: tools).tabItem { Label("External Tools", systemImage: "arrow.left.arrow.right") }
        }.frame(width: 740, height: 570)
    }
}
