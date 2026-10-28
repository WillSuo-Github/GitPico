import AppKit
import Foundation
import GitCore

@main struct GitPicoLauncher {
    @MainActor static func main() {
        if ProcessInfo.processInfo.arguments.contains("--gitpico-credential-helper") {
            GitCredentialHelper.run(arguments: ProcessInfo.processInfo.arguments, environment: ProcessInfo.processInfo.environment)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--background-testing") {
            // Verification deliberately bypasses SwiftUI scene construction and restoration.
            let application = NSApplication.shared
            let delegate = BackgroundVerificationDelegate()
            application.setActivationPolicy(.prohibited)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } else { GitPicoApp.main() }
    }
}

private final class BackgroundVerificationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--verification-output"), args.indices.contains(index + 1) else { return }
            var value: [String: Any] = [
                "backgroundTesting": true,
                "processIdentifier": ProcessInfo.processInfo.processIdentifier,
                "frontmostProcessIdentifier": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
                "isActive": NSApp.isActive,
                "visibleWindows": NSApp.windows.filter(\.isVisible).count,
                "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            ]
            if args.contains("--verify-localizations") {
                value["localization"] = [
                    "preferredLanguages": Bundle.main.preferredLocalizations,
                    "workingCopy": String(localized: "Working Copy"),
                    "modifiedStatus": localizedFileStatus("Modified"),
                    "appError": appFailure("Result is not UTF-8 text.").message,
                    "oneChangedFile": String(localized: "\(1) changed files"),
                    "threeChangedFiles": String(localized: "\(3) changed files")
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
            }
            if args.contains("--verification-exit") { NSApp.terminate(nil) }
        }
    }
}
