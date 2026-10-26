import AppKit
import GitCore
import SwiftUI

struct GitPicoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var workspace: RepositoryWorkspace { appDelegate.workspace }

    var body: some Scene {
        Settings { SettingsView(tools: workspace.activeStore.toolPreferences) }
            .commands { RepositoryCommands(store: workspace.activeStore) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let workspace: RepositoryWorkspace
    lazy var repositoryWindows = NativeRepositoryWindows(workspace: workspace, permitsPresentation: !NativeStartupVerification.enabled)
    override init() {
        workspace = NativeStartupVerification.enabled ? NativeStartupVerification.makeWorkspace() : RepositoryWorkspace()
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(NativeStartupVerification.enabled ? .prohibited : .regular)
        repositoryWindows.start()
        if NativeStartupVerification.enabled {
            Task { await NativeStartupVerification.finish(repositoryWindows) }
        } else {
            Task { await workspace.startup() }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { repositoryWindows.reopen() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if NativeStartupVerification.enabled { return .terminateNow }
        if workspace.tabs.contains(where: \.isBusy) {
            workspace.error = "Wait for repository operations to finish before quitting GitPico."
            return .terminateCancel
        }
        workspace.shutdown()
        if workspace.draftSaveWarning != nil {
            workspace.error = "Commit drafts could not be saved. Resolve the draft storage error before quitting."
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct SettingsView: View {
    let tools: ExternalToolPreferences
    @State private var preferences = AppPreferences.shared
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.01" }
    var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Development" }
    var body: some View {
        TabView {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.merge").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48).background(Pico.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GitPico").font(.system(size: 17, weight: .bold, design: .rounded))
                        Text("Version \(version) · Build \(build)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Requires macOS 26 or later").font(.caption).foregroundStyle(.tertiary)
                    }
                }.padding(.vertical, 4)
            }
            Section("Workflow") {
                Toggle("Always offer to stash local changes", isOn: $preferences.offerAutomaticStash)
            }
            Section("Diffs") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $preferences.diffFontSize, in: 10...18, step: 1).frame(width: 200)
                        Text("\(Int(preferences.diffFontSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                    }
                }
                Text("The quick brown fox jumps over the lazy dog").font(.system(size: preferences.diffFontSize, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Section {
                Label("GitPico uses your system Git identity, SSH agent, signing and repository configuration. Configure credentials with Git before synchronizing.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = preferences.lastSaveError { Text(error).foregroundStyle(Pico.deletion).font(.caption) }
        }
        .formStyle(.grouped)
        .tabItem { Label("General", systemImage: "gearshape") }
        ExternalToolSettingsView(preferences: tools).tabItem { Label("External Tools", systemImage: "arrow.left.arrow.right") }
        }.frame(width: 740, height: 570)
    }
}
