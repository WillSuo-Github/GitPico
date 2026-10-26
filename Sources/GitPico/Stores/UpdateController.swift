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
    private(set) var preparing = false
    var selectedProfile: UUID? {
        didSet { UserDefaults.standard.set(selectedProfile?.uuidString, forKey: "GitPico.UpdateProfile"); prepared = nil; readyForCheck = false; controller?.updater.httpHeaders = nil }
    }
    var githubProject: String? { Bundle.main.object(forInfoDictionaryKey: "GitPicoUpdateRepository") as? String }
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: AnyCancellable?
    @ObservationIgnored private var authentication: AuthenticationStore?
    @ObservationIgnored private var prepared: GitHubReleaseFeed?
    @ObservationIgnored private var readyForCheck = false
    private var preferenceRevision = 0
    private override init() { selectedProfile = UserDefaults.standard.string(forKey: "GitPico.UpdateProfile").flatMap(UUID.init(uuidString:)); super.init() }
    var automaticallyChecks: Bool {
        get { _ = preferenceRevision; return controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; preferenceRevision += 1 }
    }
    func startIfConfigured(authentication: AuthenticationStore) {
        self.authentication = authentication
        guard controller == nil, !ProcessInfo.processInfo.arguments.contains("--background-testing"), !NativeStartupVerification.enabled,
              let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, Data(base64Encoded: key)?.count == 32 else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller; configured = true
        observation = controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).sink { [weak self] value in self?.canCheck = value }
        controller.startUpdater()
        status = githubProject == nil ? "Updates are verified using the publisher's update signature." : "Updates use GitHub Releases. Select an account with access to the private repository."
    }
    func check() {
        guard canCheck, !preparing else { return }
        Task { if await prepareGitHubFeed() { readyForCheck = true; controller?.checkForUpdates(nil) } }
    }
    private func prepareGitHubFeed() async -> Bool {
        guard let project = githubProject else { return true }
        guard !preparing, let authentication else { return false }
        preparing = true; defer { preparing = false }
        do {
            let profiles = authentication.profiles.filter { $0.provider == .github && $0.host == "github.com" }
            guard let profile = profiles.first(where: { $0.id == selectedProfile }) ?? (profiles.count == 1 ? profiles.first : nil) else { throw GitFailure("Select a GitHub account with access to the update repository in Updates & Support.") }
            let credential = profile.isOAuth ? try await OAuthCredentialRefresher.shared.credential(profile.id) : try authentication.vault.read(profile.id)
            prepared = try await GitHubReleaseFeedClient().latest(project: project, credential: credential)
            controller?.updater.httpHeaders = ["Authorization": "Bearer " + credential.secret, "Accept": "application/octet-stream"]
            status = "Checking signed GitHub Release “" + (prepared?.tag ?? "") + "”."
            return true
        } catch { prepared = nil; controller?.updater.httpHeaders = nil; status = GitLogRedaction.clean(error.localizedDescription); return false }
    }
    func feedURLString(for updater: SPUUpdater) -> String? { prepared?.feedURL.absoluteString }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard githubProject != nil else { return }
        if readyForCheck, prepared != nil { readyForCheck = false; return }
        if !preparing {
            Task {
                if await prepareGitHubFeed(), updater.automaticallyChecksForUpdates {
                    readyForCheck = true; updater.checkForUpdatesInBackground()
                }
            }
        }
        throw GitFailure("Preparing the authenticated GitHub Release feed. Check Updates & Support for its status.")
    }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        if githubProject != nil {
            guard let prepared, let url = updateItem.fileURL, prepared.permits(url) else { throw GitFailure("The update archive is not an asset of the verified GitHub Release.") }
        }
    }
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        if githubProject != nil, request.url.map({ prepared?.permits($0) != true }) ?? true {
            request.setValue(nil, forHTTPHeaderField: "Authorization"); request.url = URL(string: "about:blank")
        }
    }
}
