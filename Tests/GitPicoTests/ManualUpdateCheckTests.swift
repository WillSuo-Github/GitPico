import AppKit
import Foundation
import GitCore
import Testing
@testable import GitPico

@MainActor private final class RecordingUpdatePresenter: UpdateCheckPresenting {
    var events: [String] = []
    var cancellation: (() -> Void)?
    func showPreparation(cancellation: @escaping () -> Void) { events.append("preparing"); self.cancellation = cancellation }
    func dismissPreparation() { events.append("dismiss") }
    func showPreparationFailure(_ message: String) { events.append("error: " + message) }
    func beginUpdateCheck() { events.append("check") }
}
private actor DelayedUpdatePreparation {
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func run() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private actor DeniedUpdateTransport: OAuthHTTPTransport {
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse { OAuthHTTPResponse(status: 404, data: Data()) }
}
@MainActor private func awaitPreparation(_ preparation: DelayedUpdatePreparation) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !(await preparation.started) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await preparation.started)
}

@Test @MainActor func manualUpdateCheckShowsProgressImmediatelyAndHandsOffOnlyOnce() async throws {
    let flow = ManualUpdateCheck(), presenter = RecordingUpdatePresenter(), preparation = DelayedUpdatePreparation()
    flow.start(presenter: presenter, prepare: { await preparation.run() }, cancelled: { Issue.record("Unexpected cancellation") })
    #expect(flow.preparing && presenter.events == ["preparing"])
    flow.start(presenter: presenter, prepare: { Issue.record("Duplicate request") }, cancelled: {})
    #expect(presenter.events == ["preparing"])
    let task = flow.task
    try await awaitPreparation(preparation); await preparation.release(); await task?.value
    #expect(!flow.preparing && presenter.events == ["preparing", "dismiss", "check"])
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func manualUpdateCheckReportsMissingAccountNetworkAndPrivateReleaseFailures() async throws {
    for kind in ["account", "network", "private-release"] {
        let flow = ManualUpdateCheck(), presenter = RecordingUpdatePresenter()
        flow.start(presenter: presenter, prepare: {
            if kind == "account" { throw GitFailure("Select a GitHub account in Updates & Support.") }
            if kind == "network" { throw URLError(.timedOut) }
            _ = try await GitHubReleaseFeedClient(transport: DeniedUpdateTransport()).latest(project: "fixture/private", credential: GitStoredCredential(host: "github.com", username: "fixture", secret: "fixture-token"))
        }, cancelled: { Issue.record("Unexpected cancellation") })
        let task = flow.task; await task?.value
        #expect(!flow.preparing && presenter.events.count == 3)
        #expect(presenter.events.first == "preparing" && presenter.events[1] == "dismiss")
        #expect(presenter.events.last?.hasPrefix("error: ") == true && !presenter.events.contains("check"))
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func cancellingManualUpdateCheckRejectsLateResultsAndAllowsRetry() async throws {
    let flow = ManualUpdateCheck(), presenter = RecordingUpdatePresenter(), preparation = DelayedUpdatePreparation()
    var cancellations = 0
    flow.start(presenter: presenter, prepare: { await preparation.run(); throw GitFailure("Late failure") }, cancelled: { cancellations += 1 })
    let oldTask = flow.task
    try await awaitPreparation(preparation)
    let oldCancellation = presenter.cancellation
    oldCancellation?()
    #expect(!flow.preparing && cancellations == 1 && presenter.events == ["preparing", "dismiss"])
    flow.start(presenter: presenter, prepare: {}, cancelled: { Issue.record("Retry was cancelled") })
    let retry = flow.task
    oldCancellation?()
    await retry?.value
    await preparation.release(); await oldTask?.value
    #expect(!flow.preparing && cancellations == 1)
    #expect(presenter.events == ["preparing", "dismiss", "preparing", "dismiss", "check"])
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func cancelledPreparationDoesNotStartSparkleOrShowAnError() async {
    let flow = ManualUpdateCheck(), presenter = RecordingUpdatePresenter()
    var cancelled = false
    flow.start(presenter: presenter, prepare: { throw CancellationError() }, cancelled: { cancelled = true })
    let task = flow.task; await task?.value
    #expect(cancelled && !flow.preparing && presenter.events == ["preparing", "dismiss"])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_DIAGNOSE_PRIVATE_UPDATE"] == "1", "Explicit noninteractive existing-account update diagnosis only."))
@MainActor func diagnoseExistingPrivateUpdateAccountWithoutWindows() async throws {
    let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GitPico/authentication.json")
    let authentication = AuthenticationStore(file: file)
    var phase = "account selection"
    var report: [String: Any] = ["succeeded": false]
    do {
        let profiles = authentication.profiles.filter { $0.provider == .github && $0.host == "github.com" }
        let selected = UpdateController.shared.selectedProfile
        guard let profile = profiles.first(where: { $0.id == selected }) ?? (profiles.count == 1 ? profiles.first : nil) else { throw GitFailure("Select a GitHub update account.") }
        phase = "account authentication"
        let credential = profile.isOAuth ? try await OAuthCredentialRefresher.shared.credential(profile.id) : try authentication.vault.read(profile.id)
        phase = "latest release lookup"
        let client = GitHubReleaseFeedClient()
        let release = try await client.latest(project: "WillSuo-Github/GitPico", credential: credential)
        phase = "signed feed resolution"
        _ = try await client.feedDownloadURL(release, credential: credential)
        report = ["succeeded": true, "tag": release.tag, "archiveCount": release.assets.count]
    } catch { report["phase"] = phase; report["error"] = GitLogRedaction.clean(error.localizedDescription) }
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_UPDATE_DIAGNOSTIC_OUTPUT"]))
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
