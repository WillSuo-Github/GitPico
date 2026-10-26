import Foundation
import GitCore
import Observation

@MainActor @Observable final class OAuthLoginController {
    private(set) var isRunning = false
    private(set) var deviceChallenge: OAuthDeviceChallenge?
    private(set) var message: String?
    private(set) var failure: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let browser: any OAuthBrowserAuthenticating
    @ObservationIgnored private let transport: any OAuthHTTPTransport
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    init(browser: (any OAuthBrowserAuthenticating)? = nil, transport: any OAuthHTTPTransport = OAuthHTTPSClient(), sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.browser = browser ?? OAuthBrowserSession(); self.transport = transport; self.sleep = sleep
    }
    func start(_ configuration: OAuthConfiguration, authentication: AuthenticationStore, root: URL?, reconnecting: AuthenticationProfile? = nil, showDevice: @escaping @MainActor (URL) -> Void = { _ in }, saved: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        isRunning = true; failure = nil; deviceChallenge = nil; message = "Starting secure sign-in…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { isRunning = false; deviceChallenge = nil; task = nil }
            do {
                let configuration = try OAuthConfiguration(provider: configuration.provider, host: configuration.host, clientID: configuration.clientID)
                let grant: OAuthTokenGrant
                if configuration.provider == .github {
                    let client = OAuthDeviceAuthorization(transport: transport)
                    let challenge = try await client.start(configuration)
                    try Task.checkCancellation()
                    deviceChallenge = challenge; message = "Enter this one-time code on GitHub, then return here."
                    showDevice(challenge.verificationURL)
                    grant = try await client.wait(challenge, configuration: configuration, sleep: sleep)
                } else {
                    let pkce = try OAuthPKCE()
                    message = "Complete authorization in the secure browser window."
                    let callback = try await browser.authenticate(pkce.authorizationURL(configuration), callbackScheme: "gitpico")
                    grant = try await OAuthCodeAuthorization(transport: transport).exchange(callback: callback, pkce: pkce, configuration: configuration)
                }
                try Task.checkCancellation()
                try grant.requireRepositoryScopes(configuration.provider)
                if configuration.provider == .gitlab, configuration.apiAccess == true, !grant.scopes.contains("api") {
                    throw GitFailure("GitLab did not grant API access. Enable the api scope in this OAuth application's registration, then review authorization again.")
                }
                deviceChallenge = nil; message = "Verifying your account…"
                let credential = GitStoredCredential(host: configuration.host, username: "", secret: grant.accessToken, oauth: grant.authorization(configuration))
                let profile = AuthenticationProfile(id: UUID(), provider: configuration.provider == .github ? .github : .gitlab, host: configuration.host, username: "", method: .oauth)
                let response = try await transport.send(HostingAccountClient.request(profile, credential: credential))
                guard response.status == 200 else { throw GitFailure("The provider could not verify this account. No credential was saved; sign in again.") }
                let account = try HostingAccountClient.account(response.data)
                try Task.checkCancellation()
                _ = try authentication.completeOAuth(configuration, grant: grant, username: account.login, root: root, reconnecting: reconnecting)
                message = "Signed in as " + account.login + ". Credentials are saved in Keychain."
                saved()
            } catch is CancellationError { message = "Sign-in cancelled. No account was changed." }
            catch { failure = GitLogRedaction.clean(error.localizedDescription); message = nil }
        }
    }
    func cancel() { task?.cancel(); browser.cancel() }
    func finishForTesting() async { await task?.value }
}
