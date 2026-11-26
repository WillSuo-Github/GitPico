import AppKit
import Foundation
import GitCore
import SwiftUI
import Synchronization
import Testing
@testable import GitPico

@Test @MainActor func externalToolSettingsDecodeLegacyJSONAndPersistTerminalAndEditorPaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-ext-app-prefs-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("external-tools.json")
    let legacyJSON = """
    {
      "version": 1,
      "diff": { "executable": "/usr/bin/opendiff", "arguments": ["{local}", "{remote}"] },
      "merge": { "executable": "/usr/bin/opendiff", "arguments": ["{local}", "{remote}", "-ancestor", "{base}", "-merge", "{merged}"] }
    }
    """
    try Data(legacyJSON.utf8).write(to: file)

    let prefs = ExternalToolPreferences(file: file)
    #expect(prefs.error == nil)
    #expect(prefs.value.terminalAppPath == nil)
    #expect(prefs.value.editorAppPath == nil)

    var updated = prefs.value
    updated.terminalAppPath = "/Applications/Ghostty.app"
    updated.editorAppPath = "/Applications/Cursor.app"
    try prefs.save(updated, expected: prefs.value)

    let reloaded = ExternalToolPreferences(file: file)
    #expect(reloaded.error == nil)
    #expect(reloaded.value.terminalAppPath == "/Applications/Ghostty.app")
    #expect(reloaded.value.editorAppPath == "/Applications/Cursor.app")

    var whitespace = reloaded.value
    whitespace.terminalAppPath = "   "
    let normalized = ExternalToolSettings(
        diff: whitespace.diff,
        merge: whitespace.merge,
        terminalAppPath: whitespace.terminalAppPath,
        editorAppPath: whitespace.editorAppPath
    )
    #expect(normalized.terminalAppPath == nil)

    var invalidRelative = reloaded.value
    invalidRelative.terminalAppPath = "Ghostty.app"
    #expect(throws: GitFailure.self) { try reloaded.save(invalidRelative) }

    var invalidNul = reloaded.value
    invalidNul.editorAppPath = "/Applications/Cursor\0.app"
    #expect(throws: GitFailure.self) { try reloaded.save(invalidNul) }

    #expect(ExternalToolPreferences(file: file).value.terminalAppPath == "/Applications/Ghostty.app")
}

@Test func externalAppDiscoveryDetectsTerminalsEditorsAndResolvesFallbacks() {
    let existingPaths: Set<String> = [
        "/System/Applications/Utilities/Terminal.app",
        "/Applications/iTerm.app",
        "/Applications/Ghostty.app",
        "/Applications/Warp.app",
        "/Applications/WezTerm.app",
        "/Applications/Alacritty.app",
        "/Applications/kitty.app",
        "/Applications/Cursor.app",
        "/Applications/Visual Studio Code.app",
        "/Applications/Zed.app",
        "/Applications/Xcode.app",
        "/Applications/Sublime Text.app",
        "/Applications/CustomCode.app"
    ]
    let bundleLookup: [String: URL] = [
        "com.apple.Terminal": URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
        "com.googlecode.iterm2": URL(fileURLWithPath: "/Applications/iTerm.app"),
        "com.mitchellh.ghostty": URL(fileURLWithPath: "/Applications/Ghostty.app"),
        "com.todesktop.230313mzl4w4u92": URL(fileURLWithPath: "/Applications/Cursor.app"),
        "com.apple.dt.Xcode": URL(fileURLWithPath: "/Applications/Xcode.app")
    ]
    let env = ExternalAppEnvironment(
        urlForBundleIdentifier: { bundleLookup[$0] },
        fileExists: { existingPaths.contains($0) },
        bundleIdentifierAtURL: { url in
            bundleLookup.first(where: { $0.value.path == url.path })?.key
        },
        displayNameAtURL: { url in
            url.lastPathComponent == "CustomCode.app" ? "Custom Code" : nil
        },
        applicationSearchDirectories: [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
        ],
        launch: { _ in }
    )

    let terminals = ExternalAppDiscovery.installedApps(for: .terminal, environment: env)
    #expect(terminals.map(\.name) == ["Terminal", "iTerm2", "Ghostty", "Warp", "WezTerm", "Alacritty", "Kitty"])

    let editors = ExternalAppDiscovery.installedApps(for: .editor, environment: env)
    #expect(editors.map(\.name) == ["Cursor", "VS Code", "Zed", "Xcode", "Sublime Text"])

    let autoTerminal = ExternalAppDiscovery.resolve(kind: .terminal, configuredPath: nil, installed: terminals, environment: env)
    #expect(autoTerminal == .automatic(terminals[0]))

    let configuredTerminal = ExternalAppDiscovery.resolve(kind: .terminal, configuredPath: "/Applications/Ghostty.app", installed: terminals, environment: env)
    #expect(configuredTerminal.app?.name == "Ghostty")

    let customEditor = ExternalAppDiscovery.resolve(kind: .editor, configuredPath: "/Applications/CustomCode.app", installed: editors, environment: env)
    #expect(customEditor.app?.name == "Custom Code")
    #expect(customEditor.app?.isKnown == false)

    let missingEditor = ExternalAppDiscovery.resolve(kind: .editor, configuredPath: "/Applications/Deleted.app", installed: editors, environment: env)
    #expect(missingEditor == .missingConfigured(path: "/Applications/Deleted.app"))

    let emptyEnv = ExternalAppEnvironment(
        urlForBundleIdentifier: { _ in nil },
        fileExists: { _ in false },
        bundleIdentifierAtURL: { _ in nil },
        displayNameAtURL: { _ in nil },
        applicationSearchDirectories: [],
        launch: { _ in }
    )
    #expect(ExternalAppDiscovery.resolve(kind: .editor, configuredPath: nil, environment: emptyEnv) == .unavailable)

    let repoDir = URL(fileURLWithPath: "/tmp/demo-repo")
    let ghostty = terminals.first { $0.name == "Ghostty" }!
    let ghosttyReq = ExternalAppDiscovery.launchRequest(for: ghostty, directory: repoDir)
    #expect(ghosttyReq.appURL == ghostty.url)
    #expect(ghosttyReq.directoryURL == repoDir)
    #expect(ghosttyReq.arguments.isEmpty)
    #expect(!ghosttyReq.createsNewInstance)

    let alacritty = terminals.first { $0.name == "Alacritty" }!
    let alacrittyReq = ExternalAppDiscovery.launchRequest(for: alacritty, directory: repoDir)
    #expect(alacrittyReq.appURL == alacritty.url)
    #expect(alacrittyReq.arguments == ["--working-directory", repoDir.path])
    #expect(alacrittyReq.createsNewInstance)
}

@Test @MainActor func repositoryStoreOpensConfiguredTerminalAndEditorForWorktreeEvenWhileBusy() async throws {
    let fixture = try await WorkingAppFixture.make(); defer { fixture.clean() }
    let mainRoot = await fixture.repository.root
    let worktreeRoot = fixture.root.appendingPathComponent("linked-wt")
    _ = try await GitProcess.run(["worktree", "add", "-b", "wt-branch", worktreeRoot.path], at: mainRoot)

    let launched = Mutex<[ExternalAppLaunchRequest]>([])
    let existing: Set<String> = ["/Applications/Ghostty.app", "/Applications/Cursor.app"]
    let env = ExternalAppEnvironment(
        urlForBundleIdentifier: { id in
            switch id {
            case "com.mitchellh.ghostty": URL(fileURLWithPath: "/Applications/Ghostty.app")
            case "com.todesktop.230313mzl4w4u92": URL(fileURLWithPath: "/Applications/Cursor.app")
            default: nil
            }
        },
        fileExists: { existing.contains($0) },
        bundleIdentifierAtURL: { url in
            if url.path == "/Applications/Ghostty.app" { return "com.mitchellh.ghostty" }
            if url.path == "/Applications/Cursor.app" { return "com.todesktop.230313mzl4w4u92" }
            return nil
        },
        displayNameAtURL: { _ in nil },
        applicationSearchDirectories: [URL(fileURLWithPath: "/Applications", isDirectory: true)],
        launch: { request in
            launched.withLock { $0.append(request) }
        }
    )
    let catalog = ExternalAppCatalog(environment: env, observesApplicationActivation: false)

    var settings = fixture.store.toolPreferences.value
    settings.terminalAppPath = "/Applications/Ghostty.app"
    settings.editorAppPath = "/Applications/Cursor.app"
    try fixture.store.toolPreferences.save(settings, expected: fixture.store.toolPreferences.value)

    fixture.store.isBusy = true
    fixture.store.openInTerminal(catalog: catalog)
    fixture.store.openInEditor(catalog: catalog)
    try await Task.sleep(for: .milliseconds(50))

    let mainRequests = launched.withLock { $0 }
    #expect(mainRequests.count == 2)
    #expect(mainRequests[0].appURL.path == "/Applications/Ghostty.app")
    #expect(mainRequests[0].directoryURL.standardizedFileURL.path == mainRoot.standardizedFileURL.path)
    #expect(mainRequests[1].appURL.path == "/Applications/Cursor.app")
    #expect(mainRequests[1].directoryURL.standardizedFileURL.path == mainRoot.standardizedFileURL.path)

    fixture.store.isBusy = false
    await fixture.store.openInPlace(worktreeRoot)
    launched.withLock { $0.removeAll() }

    fixture.store.openInTerminal(catalog: catalog)
    try await Task.sleep(for: .milliseconds(50))
    let wtRequests = launched.withLock { $0 }
    #expect(wtRequests.count == 1)
    #expect(wtRequests[0].directoryURL.standardizedFileURL.path == worktreeRoot.resolvingSymlinksInPath().path)

    var missing = fixture.store.toolPreferences.value
    missing.terminalAppPath = "/Applications/MissingTerm.app"
    try fixture.store.toolPreferences.save(missing, expected: fixture.store.toolPreferences.value)
    fixture.store.openInTerminal(catalog: catalog)
    #expect(fixture.store.error?.contains("/Applications/MissingTerm.app") == true)
}

@Test @MainActor func hostedRemoteLinksExposeGitHubAndGitLabRepositoryAndReviewURLs() async throws {
    let fixture = try await WorkingAppFixture.make(); defer { fixture.clean() }
    let root = await fixture.repository.root
    _ = try await GitProcess.run(["remote", "add", "origin", "https://github.com/octocat/hello-world.git"], at: root)
    _ = try await GitProcess.run(["remote", "add", "mirror", "git@gitlab.com:group/sub/project.git"], at: root)
    await fixture.store.openInPlace(root)

    let links = fixture.store.hostedRemoteLinks
    #expect(links.count == 2)
    let github = try #require(links.first { $0.name == "origin" })
    #expect(github.repository.provider == .github)
    #expect(github.repository.webURL.absoluteString == "https://github.com/octocat/hello-world")
    #expect(github.repository.reviewsWebURL.absoluteString == "https://github.com/octocat/hello-world/pulls")

    let gitlab = try #require(links.first { $0.name == "mirror" })
    #expect(gitlab.repository.provider == .gitlab)
    #expect(gitlab.repository.webURL.absoluteString == "https://gitlab.com/group/sub/project")
    #expect(gitlab.repository.reviewsWebURL.absoluteString == "https://gitlab.com/group/sub/project/-/merge_requests")
}

@Test @MainActor func repositoryToolbarSupportsNativeCustomizationAndMultiTabTransitionsWithoutActivation() async throws {
    let configKey = "NSToolbar Configuration \(RepositoryToolbar.customizationIdentifier)"
    let previousConfig = UserDefaults.standard.object(forKey: configKey)
    UserDefaults.standard.removeObject(forKey: configKey)
    defer {
        if let previousConfig {
            UserDefaults.standard.set(previousConfig, forKey: configKey)
        } else {
            UserDefaults.standard.removeObject(forKey: configKey)
        }
    }

    let fixture = try await WorkingAppFixture.make(); defer { fixture.clean() }
    let repoRoot = await fixture.repository.root
    let fixture2 = try await WorkingAppFixture.make(); defer { fixture2.clean() }
    let repo2Root = await fixture2.repository.root
    let workspace = RepositoryWorkspace(library: fixture.store.library)
    await workspace.open(repoRoot)
    let windows = NativeRepositoryWindows(workspace: workspace, permitsPresentation: false)
    windows.start()
    defer { windows.stop(); workspace.shutdown() }

    let repoTabID = workspace.selectedID
    let repoWindow = try #require(windows.window(for: repoTabID))
    repoWindow.setFrame(NSRect(x: -10000, y: -10000, width: 1440, height: 900), display: false)
    try await Task.sleep(for: .milliseconds(350))
    repoWindow.contentView?.superview?.layoutSubtreeIfNeeded()

    let toolbar = try #require(repoWindow.toolbar)
    #expect(toolbar.identifier == RepositoryToolbar.customizationIdentifier)
    #expect(toolbar.allowsUserCustomization)
    #expect(toolbar.autosavesConfiguration)

    let visibleIDs = toolbar.items.map(\.itemIdentifier.rawValue)
    for required in [
        "repository.back",
        "repository.forward",
        "repository.undo",
        "repository.redo",
        "repository.centerSpacing",
        "repository.fetch",
        "repository.pull",
        "repository.push",
        "repository.stash",
        "repository.terminal",
        "repository.openExternal",
        "repository.search"
    ] {
        #expect(visibleIDs.contains(required), "Missing default toolbar item \(required)")
    }
    for optionalHidden in ["repository.refresh", "repository.finder", "repository.newBranch"] {
        #expect(!visibleIDs.contains(optionalHidden), "Optional item \(optionalHidden) should be hidden by default")
    }

    if let allowed = toolbar.delegate?.toolbarAllowedItemIdentifiers?(toolbar).map(\.rawValue) {
        for customizable in ["repository.terminal", "repository.openExternal", "repository.refresh", "repository.finder", "repository.newBranch"] {
            #expect(allowed.contains(customizable), "Item \(customizable) should be available in Customize Toolbar palette")
        }
    }

    let searchItem = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "repository.search" })
    #expect(!searchItem.label.isEmpty)

    // Stress-test multi-tab transitions: Repository + Picker -> Repository -> Picker while Tab 1 remains a Repository.
    workspace.newTab(from: repoTabID)
    try await Task.sleep(for: .milliseconds(300))
    let secondTabID = workspace.selectedID
    #expect(secondTabID != repoTabID)
    await workspace.open(repo2Root)
    try await Task.sleep(for: .milliseconds(300))
    #expect(workspace.selectedID == secondTabID)
    workspace.activeStore.showRepositories()
    try await Task.sleep(for: .milliseconds(300))

    let tab1Toolbar = try #require(windows.window(for: repoTabID)?.toolbar)
    let tab1IDsAfterTransition = tab1Toolbar.items.map(\.itemIdentifier.rawValue)
    #expect(tab1Toolbar.identifier == RepositoryToolbar.customizationIdentifier)
    #expect(tab1IDsAfterTransition.contains("repository.terminal"))
    #expect(tab1IDsAfterTransition.contains("repository.openExternal"))
    let pickerToolbar = try #require(windows.window(for: secondTabID)?.toolbar)
    #expect(pickerToolbar.identifier == RepositoryPickerToolbar.toolbarIdentifier)
    #expect(!pickerToolbar.allowsUserCustomization)

    // Reopen second repo so both tabs share the customizable repository toolbar family.
    await workspace.open(repo2Root)
    try await Task.sleep(for: .milliseconds(300))
    let tab2Toolbar = try #require(windows.window(for: secondTabID)?.toolbar)
    #expect(tab2Toolbar.identifier == RepositoryToolbar.customizationIdentifier)
    #expect(tab2Toolbar.items.contains { $0.itemIdentifier.rawValue == "repository.terminal" })

    // Customize toolbar by removing Terminal and verify it updates and saves.
    let terminalIndex = try #require(tab1Toolbar.items.firstIndex { $0.itemIdentifier.rawValue == "repository.terminal" })
    tab1Toolbar.removeItem(at: terminalIndex)
    try await Task.sleep(for: .milliseconds(150))
    #expect(!tab1Toolbar.items.contains { $0.itemIdentifier.rawValue == "repository.terminal" })
    #expect(!tab2Toolbar.items.contains { $0.itemIdentifier.rawValue == "repository.terminal" })
    let savedAfterRemoval = UserDefaults.standard.dictionary(forKey: configKey)
    let savedIdentifiers = savedAfterRemoval?["TB Item Identifiers"] as? [String] ?? []
    #expect(!savedIdentifiers.contains("repository.terminal"))

    // Restore item via insertion and verify it returns.
    tab1Toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier("repository.terminal"), at: terminalIndex)
    try await Task.sleep(for: .milliseconds(150))
    #expect(tab1Toolbar.items.contains { $0.itemIdentifier.rawValue == "repository.terminal" })
    #expect(tab2Toolbar.items.contains { $0.itemIdentifier.rawValue == "repository.terminal" })

    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func externalToolSettingsViewRendersInOffscreenSettingsHostWithoutActivation() async throws {
    let fixture = try await WorkingAppFixture.make(); defer { fixture.clean() }
    let previousTab = AppSettingsNavigation.shared.selection
    AppSettingsNavigation.shared.selection = .externalTools
    defer { AppSettingsNavigation.shared.selection = previousTab }

    let host = NSHostingView(rootView: SettingsView(tools: fixture.store.toolPreferences, store: fixture.store))
    host.frame = NSRect(x: 0, y: 0, width: 740, height: 570)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    #expect(host.bounds.size == NSSize(width: 740, height: 570))

    if let path = ProcessInfo.processInfo.environment["GITPICO_SETTINGS_CAPTURE"] {
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("external-tool-settings.png"))
    }

    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
