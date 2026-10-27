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
    private var preparingFeed = false
    var preparing: Bool { preparingFeed || manualCheck.preparing }
    var githubProject: String? { Bundle.main.object(forInfoDictionaryKey: "GitPicoUpdateRepository") as? String }
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: AnyCancellable?
    @ObservationIgnored private var prepared: GitHubReleaseFeed?
    @ObservationIgnored private var preparedFeedURL: URL?
    @ObservationIgnored private var readyForCheck = false
    @ObservationIgnored private let manualCheck = ManualUpdateCheck()
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
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller; configured = true
        observation = controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).sink { [weak self] value in self?.canCheck = value }
        controller.startUpdater()
        status = githubProject == nil ? "Updates are verified using the publisher's update signature." : "Updates use public GitHub Releases. No account is required."
    }
    func check() {
        guard canCheck, !preparing, let controller else { return }
        // An existing Sparkle session may already be showing an update or download.
        if controller.updater.sessionInProgress { controller.checkForUpdates(nil); return }
        status = "Checking for updates…"
        manualCheck.start(presenter: controller, prepare: { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.prepareGitHubFeed()
            self.readyForCheck = true
        }, cancelled: { [weak self] in
            self?.clearPreparedFeed(); self?.status = "Update check cancelled."
        })
    }
    private func clearPreparedFeed() {
        prepared = nil; preparedFeedURL = nil; readyForCheck = false; controller?.updater.httpHeaders = nil
    }
    private func prepareGitHubFeed() async throws {
        guard let project = githubProject else { return }
        guard !preparingFeed else { throw GitFailure("Update checking is already being prepared. Try again shortly.") }
        preparingFeed = true; defer { preparingFeed = false }
        var phase = "looking up the latest public GitHub Release"
        do {
            let client = GitHubReleaseFeedClient()
            let release = try await client.latest(project: project)
            phase = "resolving the signed update feed"
            let feedURL = try await client.feedDownloadURL(release)
            try Task.checkCancellation()
            prepared = release; preparedFeedURL = feedURL
            controller?.updater.httpHeaders = nil
            status = "Checking signed GitHub Release “" + (prepared?.tag ?? "") + "”."
        } catch {
            clearPreparedFeed()
            if error is CancellationError { throw error }
            status = "Could not check for updates while " + phase + ". " + GitLogRedaction.clean(error.localizedDescription)
            throw GitFailure(status)
        }
    }
    func feedURLString(for updater: SPUUpdater) -> String? { preparedFeedURL?.absoluteString }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard githubProject != nil else { return }
        if readyForCheck, prepared != nil { readyForCheck = false; return }
        if !preparing {
            Task {
                do {
                    try await prepareGitHubFeed()
                    if updater.automaticallyChecksForUpdates { readyForCheck = true; updater.checkForUpdatesInBackground() }
                } catch {
                    // Scheduled checks keep their failure in Settings; manual checks show it above.
                }
            }
        }
        throw GitFailure("Preparing the public GitHub Release feed. Check Updates & Support for its status.")
    }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        if githubProject != nil {
            guard let prepared, let url = updateItem.fileURL, prepared.permits(url) else { throw GitFailure("The update archive is not an asset of the verified GitHub Release.") }
        }
    }
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        guard githubProject != nil else { return }
        do {
            guard let prepared else { throw GitFailure("The update release has not been verified.") }
            try prepared.configurePublicDownload(request)
        } catch {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "Cookie")
            request.httpShouldHandleCookies = false
            request.url = URL(string: "about:blank")
        }
    }
}
