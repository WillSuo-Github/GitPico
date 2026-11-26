import AppKit
import Foundation
import GitCore
import Observation

enum ExternalAppKind: String, CaseIterable, Sendable {
    case terminal
    case editor
}

struct ExternalAppDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let kind: ExternalAppKind
    let displayName: String
    let bundleIdentifiers: [String]
    let appBundleNames: [String]
    let additionalPaths: [String]
}

struct InstalledExternalApp: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let kind: ExternalAppKind
    let name: String
    let url: URL
    let bundleIdentifier: String?
    let isKnown: Bool

    var path: String { url.path }
}

enum ResolvedExternalApp: Equatable, Sendable {
    case configured(InstalledExternalApp)
    case missingConfigured(path: String)
    case automatic(InstalledExternalApp)
    case unavailable

    var app: InstalledExternalApp? {
        switch self {
        case .configured(let app), .automatic(let app): app
        case .missingConfigured, .unavailable: nil
        }
    }
}

struct ExternalAppLaunchRequest: Equatable, Sendable {
    let appURL: URL
    let directoryURL: URL
    let arguments: [String]
    let createsNewInstance: Bool
}

struct ExternalAppEnvironment: Sendable {
    var urlForBundleIdentifier: @Sendable (String) -> URL?
    var fileExists: @Sendable (String) -> Bool
    var bundleIdentifierAtURL: @Sendable (URL) -> String?
    var displayNameAtURL: @Sendable (URL) -> String?
    var applicationSearchDirectories: [URL]
    var launch: @MainActor @Sendable (ExternalAppLaunchRequest) async throws -> Void

    static let live = ExternalAppEnvironment(
        urlForBundleIdentifier: { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        },
        fileExists: { path in
            FileManager.default.fileExists(atPath: path)
        },
        bundleIdentifierAtURL: { url in
            Bundle(url: url)?.bundleIdentifier
        },
        displayNameAtURL: { url in
            let bundle = Bundle(url: url)
            if let display = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !display.isEmpty {
                return display
            }
            if let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
            return nil
        },
        applicationSearchDirectories: [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
        ],
        launch: { request in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = request.createsNewInstance
            if request.arguments.isEmpty {
                _ = try await NSWorkspace.shared.open(
                    [request.directoryURL],
                    withApplicationAt: request.appURL,
                    configuration: configuration
                )
            } else {
                configuration.arguments = request.arguments
                _ = try await NSWorkspace.shared.openApplication(
                    at: request.appURL,
                    configuration: configuration
                )
            }
        }
    )
}

enum ExternalAppDiscovery {
    static let knownTerminals: [ExternalAppDescriptor] = [
        ExternalAppDescriptor(
            id: "terminal",
            kind: .terminal,
            displayName: "Terminal",
            bundleIdentifiers: ["com.apple.Terminal"],
            appBundleNames: ["Terminal.app"],
            additionalPaths: ["/System/Applications/Utilities/Terminal.app"]
        ),
        ExternalAppDescriptor(
            id: "iterm2",
            kind: .terminal,
            displayName: "iTerm2",
            bundleIdentifiers: ["com.googlecode.iterm2"],
            appBundleNames: ["iTerm.app", "iTerm2.app"],
            additionalPaths: []
        ),
        ExternalAppDescriptor(
            id: "ghostty",
            kind: .terminal,
            displayName: "Ghostty",
            bundleIdentifiers: ["com.mitchellh.ghostty"],
            appBundleNames: ["Ghostty.app"],
            additionalPaths: []
        ),
        ExternalAppDescriptor(
            id: "warp",
            kind: .terminal,
            displayName: "Warp",
            bundleIdentifiers: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"],
            appBundleNames: ["Warp.app", "WarpPreview.app"],
            additionalPaths: []
        ),
        ExternalAppDescriptor(
            id: "wezterm",
            kind: .terminal,
            displayName: "WezTerm",
            bundleIdentifiers: ["com.github.wez.wezterm"],
            appBundleNames: ["WezTerm.app"],
            additionalPaths: []
        ),
        ExternalAppDescriptor(
            id: "alacritty",
            kind: .terminal,
            displayName: "Alacritty",
            bundleIdentifiers: ["org.alacritty"],
            appBundleNames: ["Alacritty.app"],
            additionalPaths: []
        ),
        ExternalAppDescriptor(
            id: "kitty",
            kind: .terminal,
            displayName: "Kitty",
            bundleIdentifiers: ["net.kovidgoyal.kitty"],
            appBundleNames: ["kitty.app", "Kitty.app"],
            additionalPaths: []
        )
    ]

    static let knownEditors: [ExternalAppDescriptor] = [
        ExternalAppDescriptor(
            id: "cursor",
            kind: .editor,
            displayName: "Cursor",
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            appBundleNames: ["Cursor.app"],
            additionalPaths: []
        ),
        ExternalAppDescriptor(
            id: "vscode",
            kind: .editor,
            displayName: "VS Code",
            bundleIdentifiers: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
            appBundleNames: ["Visual Studio Code.app", "Visual Studio Code - Insiders.app"],
            additionalPaths: []
        ),
        ExternalAppDescriptor(
            id: "zed",
            kind: .editor,
            displayName: "Zed",
            bundleIdentifiers: ["dev.zed.Zed", "dev.zed.Zed-Preview"],
            appBundleNames: ["Zed.app", "Zed Preview.app"],
            additionalPaths: []
        ),
        ExternalAppDescriptor(
            id: "xcode",
            kind: .editor,
            displayName: "Xcode",
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            appBundleNames: ["Xcode.app"],
            additionalPaths: []
        ),
        ExternalAppDescriptor(
            id: "sublime",
            kind: .editor,
            displayName: "Sublime Text",
            bundleIdentifiers: ["com.sublimetext.4", "com.sublimetext.3", "com.sublimetext.2"],
            appBundleNames: ["Sublime Text.app"],
            additionalPaths: []
        )
    ]

    static func descriptors(for kind: ExternalAppKind) -> [ExternalAppDescriptor] {
        switch kind {
        case .terminal: knownTerminals
        case .editor: knownEditors
        }
    }

    static func installedApps(
        for kind: ExternalAppKind,
        environment: ExternalAppEnvironment = .live
    ) -> [InstalledExternalApp] {
        var results: [InstalledExternalApp] = []
        var seenPaths: Set<String> = []

        for descriptor in descriptors(for: kind) {
            guard let url = locate(descriptor, environment: environment) else { continue }
            let standardized = url.standardizedFileURL.path
            guard seenPaths.insert(standardized).inserted else { continue }
            let bundleID = environment.bundleIdentifierAtURL(url) ?? descriptor.bundleIdentifiers.first
            results.append(
                InstalledExternalApp(
                    id: standardized,
                    kind: kind,
                    name: descriptor.displayName,
                    url: URL(fileURLWithPath: standardized),
                    bundleIdentifier: bundleID,
                    isKnown: true
                )
            )
        }

        return results
    }

    static func resolve(
        kind: ExternalAppKind,
        configuredPath: String?,
        installed: [InstalledExternalApp]? = nil,
        environment: ExternalAppEnvironment = .live
    ) -> ResolvedExternalApp {
        let detected = installed ?? installedApps(for: kind, environment: environment)
        if let configuredPath = ExternalToolSettings.normalizedAppPath(configuredPath) {
            let standardized = URL(fileURLWithPath: configuredPath).standardizedFileURL.path
            if let matched = detected.first(where: { $0.url.standardizedFileURL.path == standardized }) {
                return .configured(matched)
            }
            if environment.fileExists(standardized) {
                let url = URL(fileURLWithPath: standardized)
                let app = describeApp(at: url, kind: kind, environment: environment)
                return .configured(app)
            }
            return .missingConfigured(path: configuredPath)
        }
        if let first = detected.first {
            return .automatic(first)
        }
        return .unavailable
    }

    static func describeApp(
        at url: URL,
        kind: ExternalAppKind,
        environment: ExternalAppEnvironment = .live
    ) -> InstalledExternalApp {
        let standardized = url.standardizedFileURL
        let bundleID = environment.bundleIdentifierAtURL(standardized)
        let known = descriptors(for: kind).first { descriptor in
            if let bundleID, descriptor.bundleIdentifiers.contains(bundleID) { return true }
            return descriptor.appBundleNames.contains { $0.caseInsensitiveCompare(standardized.lastPathComponent) == .orderedSame }
        }
        let fallbackName = environment.displayNameAtURL(standardized)
            ?? standardized.deletingPathExtension().lastPathComponent
        return InstalledExternalApp(
            id: standardized.path,
            kind: kind,
            name: known?.displayName ?? fallbackName,
            url: standardized,
            bundleIdentifier: bundleID ?? known?.bundleIdentifiers.first,
            isKnown: known != nil
        )
    }

    static func launchRequest(for app: InstalledExternalApp, directory: URL) -> ExternalAppLaunchRequest {
        let isAlacritty = app.bundleIdentifier == "org.alacritty"
            || app.url.lastPathComponent.caseInsensitiveCompare("Alacritty.app") == .orderedSame
        if app.kind == .terminal && isAlacritty {
            return ExternalAppLaunchRequest(
                appURL: app.url,
                directoryURL: directory,
                arguments: ["--working-directory", directory.path],
                createsNewInstance: true
            )
        }
        return ExternalAppLaunchRequest(
            appURL: app.url,
            directoryURL: directory,
            arguments: [],
            createsNewInstance: false
        )
    }

    private static func locate(_ descriptor: ExternalAppDescriptor, environment: ExternalAppEnvironment) -> URL? {
        for bundleID in descriptor.bundleIdentifiers {
            if let url = environment.urlForBundleIdentifier(bundleID), environment.fileExists(url.path) {
                return url
            }
        }
        for path in descriptor.additionalPaths where environment.fileExists(path) {
            return URL(fileURLWithPath: path)
        }
        for directory in environment.applicationSearchDirectories {
            for bundleName in descriptor.appBundleNames {
                let candidate = directory.appendingPathComponent(bundleName, isDirectory: true)
                if environment.fileExists(candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}

@MainActor @Observable final class ExternalAppCatalog {
    static let shared = ExternalAppCatalog()

    private(set) var installedTerminals: [InstalledExternalApp] = []
    private(set) var installedEditors: [InstalledExternalApp] = []
    @ObservationIgnored var environment: ExternalAppEnvironment
    @ObservationIgnored private nonisolated(unsafe) var activationObserver: NSObjectProtocol?

    init(environment: ExternalAppEnvironment = .live, observesApplicationActivation: Bool = true) {
        self.environment = environment
        refresh()
        if observesApplicationActivation {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    func refresh() {
        installedTerminals = ExternalAppDiscovery.installedApps(for: .terminal, environment: environment)
        installedEditors = ExternalAppDiscovery.installedApps(for: .editor, environment: environment)
    }

    func installedApps(for kind: ExternalAppKind) -> [InstalledExternalApp] {
        switch kind {
        case .terminal: installedTerminals
        case .editor: installedEditors
        }
    }

    func resolve(kind: ExternalAppKind, settings: ExternalToolSettings) -> ResolvedExternalApp {
        let configuredPath = kind == .terminal ? settings.terminalAppPath : settings.editorAppPath
        return ExternalAppDiscovery.resolve(
            kind: kind,
            configuredPath: configuredPath,
            installed: installedApps(for: kind),
            environment: environment
        )
    }

    func open(directory: URL, in app: InstalledExternalApp) async throws {
        guard environment.fileExists(app.path) else {
            throw appFailure("The application “\(app.name)” could not be found at \(app.path).")
        }
        let request = ExternalAppDiscovery.launchRequest(for: app, directory: directory)
        try await environment.launch(request)
    }
}

extension InstalledExternalApp {
    @MainActor var menuIcon: NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        let copy = (icon.copy() as? NSImage) ?? icon
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}
