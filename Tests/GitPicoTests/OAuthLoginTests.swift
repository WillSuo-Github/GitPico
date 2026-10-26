import Foundation
import GitCore
import Synchronization
import Testing
@testable import GitPico

@Test @MainActor func oauthBrowserCompletionAcceptsBackgroundSuccessAndCancellation() async {
    let url = URL(string: "gitpico://oauth/gitlab/callback?code=fixture&state=fixture")!
    for cancelled in [false, true] {
        let returned: URL? = await withCheckedContinuation { continuation in
            let completion = OAuthBrowserSession.mainActorCompletion { callback, error in
                MainActor.preconditionIsolated()
                if cancelled { #expect(error is CancellationError) }
                else { #expect(error == nil) }
                continuation.resume(returning: callback)
            }
            DispatchQueue.global().async {
                completion(cancelled ? nil : url, cancelled ? CancellationError() : nil)
            }
        }
        #expect(returned == (cancelled ? nil : url))
    }
}

private final class LoginVault: CredentialStoring, Sendable {
    let values = Mutex<[UUID: GitStoredCredential]>([:])
    func read(_ id: UUID) throws -> GitStoredCredential { guard let value = values.withLock({ $0[id] }) else { throw GitFailure("Missing fixture credential") }; return value }
    func save(_ value: GitStoredCredential, id: UUID) throws { values.withLock { $0[id] = value } }
    func remove(_ id: UUID) throws { values.withLock { $0.removeValue(forKey: id) } }
}
private actor LoginTransport: OAuthHTTPTransport {
    var requests: [URLRequest] = []
    var responses: [OAuthHTTPResponse]
    init(responses: [OAuthHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw GitFailure("No fixture response") }
        return responses.removeFirst()
    }
}
private func loginTransport(_ values: [[String: Any]]) throws -> LoginTransport { LoginTransport(responses: try values.map { OAuthHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: $0)) }) }
@MainActor private final class LoginBrowser: OAuthBrowserAuthenticating {
    enum ResultMode { case success, denied, wrongState, waiting }
    var mode: ResultMode
    var started = false
    init(_ mode: ResultMode = .success) { self.mode = mode }
    func authenticate(_ url: URL, callbackScheme: String) async throws -> URL {
        started = true
        if mode == .waiting { try await Task.sleep(for: .seconds(60)); throw CancellationError() }
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "gitpico://oauth/gitlab/callback?state=" + (mode == .wrongState ? "wrong" : state) + (mode == .denied ? "&error=access_denied" : "&code=fixture-code"))!
    }
    func cancel() {}
}
@MainActor private struct LoginFixture {
    let directory: URL
    let vault: LoginVault
    let store: AuthenticationStore
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-login-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vault = LoginVault(); store = AuthenticationStore(file: directory.appendingPathComponent("authentication.json"), vault: vault)
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
}
private func loginGrant(_ provider: OAuthProvider) -> [String: Any] { ["access_token":"fixture-access", "refresh_token":"fixture-refresh", "token_type":"bearer", "expires_in":7200, "scope":provider == .github ? "repo read:user" : "read_user write_repository"] }
private func tokenGrant(_ provider: OAuthProvider) throws -> OAuthTokenGrant { try OAuthRequests.grant(OAuthHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: loginGrant(provider)))) }

@Test @MainActor func gitlabBrowserLoginVerifiesBearerIdentityBeforeSavingSecretsAndCapturedAssignment() async throws {
    let f = try LoginFixture(); defer { f.clean() }
    let transport = try loginTransport([loginGrant(.gitlab), ["username":"fixture-user"]]), browser = LoginBrowser()
    let login = OAuthLoginController(browser: browser, transport: transport)
    let originalRoot = f.directory.appendingPathComponent("OriginalRepo")
    var saved = false
    login.start(try OAuthAppCatalog.configuration(.gitlab), authentication: f.store, root: originalRoot) { saved = true }
    await login.finishForTesting()
    #expect(saved && !login.isRunning && login.failure == nil && browser.started)
    let profile = try #require(f.store.profile(for: originalRoot))
    #expect(profile.isOAuth && profile.username == "fixture-user")
    let credential = try f.vault.read(profile.id)
    #expect(credential.secret == "fixture-access" && credential.oauth?.refreshToken == "fixture-refresh")
    let metadata = try String(contentsOf: f.store.file, encoding: .utf8)
    #expect(!metadata.contains("fixture-access") && !metadata.contains("fixture-refresh"))
    let requests = await transport.requests
    #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
    #expect(requests.last?.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil)
    #expect(AuthenticationStore(file: f.store.file, vault: f.vault).profile(for: originalRoot)?.isOAuth == true)
}

@Test @MainActor func githubDeviceLoginUsesRegisteredPublicClientAndVerifiesIdentityBeforeSaving() async throws {
    let f = try LoginFixture(); defer { f.clean() }
    let transport = try loginTransport([["device_code":"fixture-device", "user_code":"ABCD-EFGH", "verification_uri":"https://github.com/login/device", "expires_in":900, "interval":5], loginGrant(.github), ["login":"fixture-user"]])
    let browser = LoginBrowser(), login = OAuthLoginController(browser: browser, transport: transport, sleep: { _ in })
    var presented: URL?
    login.start(try OAuthAppCatalog.configuration(.github), authentication: f.store, root: nil, showDevice: { presented = $0 }) {}
    await login.finishForTesting()
    #expect(login.failure == nil && f.store.profiles.count == 1 && f.store.profiles[0].isOAuth)
    #expect(presented?.absoluteString == "https://github.com/login/device" && !browser.started && login.deviceChallenge == nil)
    let requests = await transport.requests
    #expect(String(decoding: requests[0].httpBody ?? Data(), as: UTF8.self).contains("client_id=Ov23liSrQZqjI0HkLbHN"))
    #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
}

@Test @MainActor func declinedMismatchedOrCancelledOAuthLoginNeverSavesAnAccount() async throws {
    for mode in [LoginBrowser.ResultMode.denied, .wrongState, .waiting] {
        let f = try LoginFixture(); defer { f.clean() }
        let browser = LoginBrowser(mode), transport = try loginTransport([])
        let login = OAuthLoginController(browser: browser, transport: transport)
        login.start(try OAuthAppCatalog.configuration(.gitlab), authentication: f.store, root: nil) { Issue.record("A rejected sign-in must not save") }
        if mode == .waiting {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !browser.started, ContinuousClock.now < deadline { await Task.yield() }
            login.cancel()
        }
        await login.finishForTesting()
        #expect(!login.isRunning && f.store.profiles.isEmpty && f.vault.values.withLock { $0.isEmpty })
        #expect(await transport.requests.isEmpty)
    }
}

@Test @MainActor func invalidOAuthIdentityAndPartialPermissionsAreRejectedBeforeKeychainSave() async throws {
    let f = try LoginFixture(); defer { f.clean() }
    for values in [[loginGrant(.gitlab), [:]], [["access_token":"fixture", "token_type":"bearer", "scope":"read_user"]]] {
        let transport = try loginTransport(values), login = OAuthLoginController(browser: LoginBrowser(), transport: transport)
        login.start(try OAuthAppCatalog.configuration(.gitlab), authentication: f.store, root: nil) { Issue.record("Invalid identity/grant must not save") }
        await login.finishForTesting()
        #expect(login.failure != nil && f.store.profiles.isEmpty && f.vault.values.withLock { $0.isEmpty })
    }
}

@Test @MainActor func oauthReconnectKeepsBindingsAndRejectsDifferentAccountsOrPATReplacement() throws {
    let f = try LoginFixture(); defer { f.clean() }
    let config = try OAuthAppCatalog.configuration(.gitlab), root = f.directory.appendingPathComponent("Repo")
    let profile = try f.store.completeOAuth(config, grant: tokenGrant(.gitlab), username: "fixture-user", root: root)
    #expect(throws: GitFailure.self) { _ = try f.store.completeOAuth(config, grant: tokenGrant(.gitlab), username: "different-user", root: nil, reconnecting: profile) }
    #expect(throws: GitFailure.self) { try f.store.replaceToken(profile, token: "manual-token") }
    let renewed = try f.store.completeOAuth(config, grant: tokenGrant(.gitlab), username: "fixture-user", root: nil, reconnecting: profile)
    #expect(renewed.id == profile.id && f.store.profile(for: root)?.id == profile.id && f.store.profiles.count == 1)
    try Data("external settings".utf8).write(to: f.store.file)
    #expect(throws: GitFailure.self) { _ = try f.store.completeOAuth(config, grant: tokenGrant(.gitlab), username: "second", root: nil) }
    #expect(f.vault.values.withLock { $0.count } == 1)
}

@Test @MainActor func existingPersonalTokenProfilesDecodeWithoutOAuthMetadata() throws {
    let f = try LoginFixture(); defer { f.clean() }
    let id = UUID()
    let document: [String: Any] = ["profiles":[["id":id.uuidString, "provider":"GitHub", "host":"github.com", "username":"legacy"]], "assignments":[:]]
    try JSONSerialization.data(withJSONObject: document).write(to: f.store.file)
    f.store.reload()
    #expect(f.store.error == nil && f.store.profiles.count == 1 && !f.store.profiles[0].isOAuth)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_VERIFY_OAUTH_REGISTRATION"] == "1", "Explicit unauthenticated public-client registration probe; no browser or account grant."))
@MainActor func registeredGitHubOAuthClientCanRequestADeviceCodeWithoutAuthorizingAnAccount() async throws {
    let challenge = try await OAuthDeviceAuthorization().start(OAuthAppCatalog.configuration(.github))
    #expect(challenge.verificationURL.absoluteString == "https://github.com/login/device")
    #expect(challenge.expiresAt > Date() && !challenge.userCode.isEmpty && !challenge.deviceCode.isEmpty)
    if let output = ProcessInfo.processInfo.environment["GITPICO_OAUTH_REGISTRATION_REPORT"] {
        let object: [String: Any] = ["provider":"GitHub", "clientID":try OAuthAppCatalog.configuration(.github).clientID, "deviceEndpointAccepted":true, "browserOpened":false, "accountAuthorized":false, "tokenStored":false, "verificationURL":challenge.verificationURL.absoluteString]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
