import AppKit
import Combine
import Foundation
import GitCore
import Observation
import Sparkle

@MainActor @Observable final class UpdateController: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateController()
    private(set) var configured = false
    private(set) var canCheck = false
    private(set) var status = "Updates are not configured for this development build."
    var githubProject: String? { Bundle.main.object(forInfoDictionaryKey: "GitPicoUpdateRepository") as? String }
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: AnyCancellable?
    private var preferenceRevision = 0
    private override init() { super.init() }
    var automaticallyChecks: Bool {
        get { _ = preferenceRevision; return controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; preferenceRevision += 1 }
    }
    func startIfConfigured() {
        guard controller == nil, !ProcessInfo.processInfo.arguments.contains("--background-testing"), !NativeStartupVerification.enabled,
              let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, Data(base64Encoded: key)?.count == 32 else { return }
        if let project = githubProject {
            guard let source = try? GitHubPublicRelease(project: project), source.feedURL == url else {
                status = "The public GitHub update feed URL does not match the configured repository."
                return
            }
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller; configured = true
        observation = controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).sink { [weak self] value in self?.canCheck = value }
        controller.startUpdater()
        status = githubProject == nil ? "Updates are verified using the publisher's update signature." : "Updates use public GitHub Releases. No account is required."
    }
    func check() {
        guard canCheck, let controller else { return }
        // Sparkle immediately owns progress, cancellation and visible errors.
        // Public downloads need no account preparation or REST release lookup.
        controller.checkForUpdates(nil)
    }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard let project = githubProject else { return }
        let source = try GitHubPublicRelease(project: project)
        guard let url = updateItem.fileURL, source.permits(url, build: updateItem.versionString) else {
            throw GitFailure("The update archive is not the expected public GitHub release download.")
        }
    }
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        guard let project = githubProject else { return }
        do {
            try GitHubPublicRelease(project: project).configureDownload(request, build: item.versionString)
        } catch {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "Cookie")
            request.httpShouldHandleCookies = false
            request.url = URL(string: "about:blank")
        }
    }
}
