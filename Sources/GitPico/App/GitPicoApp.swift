import AppKit
import GitCore
import SwiftUI

struct GitPicoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var workspace: RepositoryWorkspace { appDelegate.workspace }

    var body: some Scene {
        Settings { SettingsView(tools: workspace.activeStore.toolPreferences, store: workspace.activeStore) }
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
            UpdateController.shared.startIfConfigured()
            workspace.startMonitoring()
            let notifications = NSWorkspace.shared.notificationCenter
            notifications.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
            notifications.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
            Task { await workspace.startup() }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { repositoryWindows.reopen() }
        return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if !NativeStartupVerification.enabled { workspace.refreshExternalChanges() }
    }
    @objc nonisolated private func systemWillSleep(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.workspace.prepareForSleep() }
    }
    @objc nonisolated private func systemDidWake(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.workspace.resumeAfterWake() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if NativeStartupVerification.enabled { return .terminateNow }
        if workspace.tabs.contains(where: \.isBusy) || workspace.networkActivity.runningCount > 0 {
            workspace.error = "Wait for repository operations to finish before quitting GitPico."
            return .terminateCancel
        }
        workspace.shutdown()
        if workspace.draftSaveWarning != nil {
            workspace.error = "Drafts could not be saved. Resolve the draft storage error before quitting."
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct SettingsView: View {
    let tools: ExternalToolPreferences
    let store: RepositoryStore
    @State private var preferences = AppPreferences.shared
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }
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
                Toggle("Restore repositories and windows on launch", isOn: $preferences.resumeWorkspace)
                Picker("Default Pull strategy", selection: $preferences.pullPolicy) {
                    ForEach(PullPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(preferences.pullPolicy.explanation).font(.caption).foregroundStyle(.secondary)
                Toggle("Always offer to stash local changes", isOn: $preferences.offerAutomaticStash)
                Toggle("Fetch remote updates in the background", isOn: $preferences.backgroundFetch)
                Text("Every five minutes while an open repository is idle. Uses connected HTTPS accounts or unlocked SSH keys, never Pulls or Pushes, and reports failures in Network Activity without prompting.").font(.caption).foregroundStyle(.secondary)
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
                Label("Connect HTTPS accounts in Authentication, or use your existing system Git credentials and SSH agent. Signing continues to use your repository configuration.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = preferences.lastSaveError { Text(error).foregroundStyle(Pico.deletion).font(.caption) }
        }
        .formStyle(.grouped)
        .tabItem { Label("General", systemImage: "gearshape") }
        CommitWorkflowSettingsView().tabItem { Label("Commits", systemImage: "doc.text") }
        AICommitSettingsView().tabItem { Label("AI Commits", systemImage: "sparkles") }
        ExternalToolSettingsView(preferences: tools).tabItem { Label("External Tools", systemImage: "arrow.left.arrow.right") }
        AuthenticationSettingsView(store: store).tabItem { Label("Authentication", systemImage: "person.badge.key") }
        SSHKeysSettingsView().tabItem { Label("SSH Keys", systemImage: "key") }
        UpdatesSettingsView(store: store).tabItem { Label("Updates & Support", systemImage: "arrow.down.circle") }
        }.frame(width: 740, height: 570)
    }
}
