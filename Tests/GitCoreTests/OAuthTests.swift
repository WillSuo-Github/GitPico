import Foundation
import Synchronization
import Testing
@testable import GitCore

actor OAuthFixtureTransport: OAuthHTTPTransport {
    var requests: [URLRequest] = []
    var responses: [OAuthHTTPResponse]
    let delay: Duration
    init(_ values: [[String: Any]], status: Int = 200, delay: Duration = .zero) throws {
        responses = try values.map { OAuthHTTPResponse(status: status, data: try JSONSerialization.data(withJSONObject: $0)) }; self.delay = delay
    }
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        requests.append(request)
        if delay > .zero { try await Task.sleep(for: delay) }
        guard !responses.isEmpty else { throw GitFailure("No fixture response") }
        return responses.removeFirst()
    }
}
private final class OAuthFixtureVault: OAuthCredentialStorage, Sendable {
    let values = Mutex<[UUID: GitStoredCredential]>([:])
    func read(_ id: UUID) throws -> GitStoredCredential { guard let value = values.withLock({ $0[id] }) else { throw GitFailure("Missing fixture credential") }; return value }
    func save(_ value: GitStoredCredential, id: UUID) throws { values.withLock { $0[id] = value } }
}
private func oauthResponse(_ object: [String: Any], status: Int = 200) throws -> OAuthHTTPResponse { OAuthHTTPResponse(status: status, data: try JSONSerialization.data(withJSONObject: object)) }
private func grantObject(_ provider: OAuthProvider = .gitlab) -> [String: Any] { ["access_token":"new-fixture-access", "refresh_token":"new-fixture-refresh", "expires_in":7200, "token_type":"Bearer", "scope":provider == .github ? "repo,read:user" : "read_user write_repository"] }

@Test func oauthPKCEUsesRFCVectorAndChecksExactCallbackAndUniqueState() throws {
    let config = try OAuthConfiguration(provider: .gitlab, host: "gitlab.com", clientID: "fixture-client")
    let pkce = OAuthPKCE(state: "fixture-state", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let url = try pkce.authorizationURL(config)
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.first { $0.name == "code_challenge_method" }?.value == "S256")
    #expect(query.first { $0.name == "redirect_uri" }?.value == config.callback.absoluteString)
    #expect(!url.absoluteString.contains(pkce.verifier))
    #expect(try pkce.code(from: URL(string: "gitpico://oauth/gitlab/callback?state=fixture-state&code=fixture-code")!, configuration: config) == "fixture-code")
    for raw in ["gitpico://other/gitlab/callback?state=fixture-state&code=c", "gitpico://oauth/gitlab/wrong?state=fixture-state&code=c", "gitpico://oauth/github/callback?state=fixture-state&code=c", "gitpico://oauth/gitlab/callback?state=wrong&code=c", "gitpico://oauth/gitlab/callback?state=fixture-state&state=fixture-state&code=c", "gitpico://oauth/gitlab/callback?state=fixture-state&code=c&code=d", "gitpico://oauth/gitlab/callback?state=fixture-state&error=access_denied", "gitpico://oauth/gitlab/callback?state=fixture-state&code=c#fragment"] {
        #expect(throws: GitFailure.self) { _ = try pkce.code(from: URL(string: raw)!, configuration: config) }
    }
    let random = try OAuthPKCE(), another = try OAuthPKCE()
    #expect(random.state.count == 43 && random.verifier.count == 43 && random.state != another.state && random.verifier != another.verifier)
}

@Test func oauthConfigurationAndFormRejectAmbiguousEndpointsAndEncodeSecretsInBodyOnly() throws {
    for host in ["http://gitlab.com", "user@gitlab.com", "gitlab.com/path", "gitlab.com?token=a", "gitlab.com\n"] { #expect(throws: GitFailure.self) { _ = try OAuthConfiguration(provider: .gitlab, host: host, clientID: "fixture") } }
    let config = try OAuthConfiguration(provider: .gitlab, host: "git.example.invalid:8443", clientID: "fixture-client")
    let request = OAuthRequests.form(config.tokenURL, [("code_verifier", "plus+ amp& equals= percent%")])
    #expect(request.url?.query == nil && request.httpMethod == "POST")
    #expect(String(decoding: try #require(request.httpBody), as: UTF8.self) == "code_verifier=plus%2B%20amp%26%20equals%3D%20percent%25")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
}

@Test func oauthGrantValidatesExpiryScopeAndNeverReportsProviderSecretsOnErrors() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let grant = try OAuthRequests.grant(oauthResponse(grantObject()), now: now)
    #expect(grant.expiresAt == now.addingTimeInterval(7200) && grant.refreshToken == "new-fixture-refresh")
    try grant.requireRepositoryScopes(.gitlab)
    for object in [["access_token":"fixture", "token_type":"bearer", "expires_in":0], ["access_token":"fixture", "token_type":"bearer", "expires_in":7200], ["access_token":"bad\nvalue", "token_type":"bearer"], ["access_token":"fixture", "token_type":"MAC"], ["access_token":"fixture", "token_type":"bearer", "refresh_token":"bad\nrefresh"]] as [[String: Any]] {
        #expect(throws: GitFailure.self) { _ = try OAuthRequests.grant(oauthResponse(object), now: now) }
    }
    let limited = try OAuthRequests.grant(oauthResponse(["access_token":"fixture", "token_type":"bearer", "scope":"read_user"]))
    #expect(throws: GitFailure.self) { try limited.requireRepositoryScopes(.gitlab) }
    do { _ = try OAuthRequests.grant(oauthResponse(["error":"invalid_grant", "error_description":"private-fixture-secret"], status: 400)); Issue.record("Expected rejected grant") }
    catch { #expect(!error.localizedDescription.contains("private-fixture-secret")) }
}

@Test func githubDeviceFlowHonorsPendingSlowDownAndUsesNoClientSecret() async throws {
    let start = Date(timeIntervalSince1970: 2_000_000_000), clock = Mutex(start), delays = Mutex<[Double]>([])
    let config = try OAuthConfiguration(provider: .github, host: "github.com", clientID: "fixture-client")
    let transport = try OAuthFixtureTransport([["device_code":"fixture-device", "user_code":"ABCD-EFGH", "verification_uri":"https://github.com/login/device", "expires_in":900, "interval":5], ["error":"authorization_pending"], ["error":"slow_down", "interval":12], grantObject(.github)])
    let client = OAuthDeviceAuthorization(transport: transport), challenge = try await client.start(config, now: start)
    let grant = try await client.wait(challenge, configuration: config, now: { clock.withLock { $0 } }, sleep: { interval in delays.withLock { $0.append(interval) }; clock.withLock { $0 += interval } })
    #expect(grant.accessToken == "new-fixture-access")
    #expect(delays.withLock { $0 } == [5, 5, 12])
    let requests = await transport.requests
    #expect(requests.count == 4)
    #expect(requests.allSatisfy { $0.url?.scheme == "https" && $0.url?.query == nil && !String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("client_secret") })
    #expect(requests.last?.url == config.tokenURL)
}

@Test func deviceFlowRejectsOffHostVerificationAndStopsOnDenialExpiryOrCancellation() async throws {
    let config = try OAuthConfiguration(provider: .github, host: "github.com", clientID: "fixture")
    for url in ["http://github.com/login/device", "https://other.invalid/login/device", "https://github.com/login/device?token=bad", "https://github.com/other"] {
        let transport = try OAuthFixtureTransport([["device_code":"fixture", "user_code":"ABCD-EFGH", "verification_uri":url, "expires_in":900, "interval":5]])
        await #expect(throws: GitFailure.self) { _ = try await OAuthDeviceAuthorization(transport: transport).start(config) }
    }
    let challenge = OAuthDeviceChallenge(deviceCode: "fixture", userCode: "ABCD-EFGH", verificationURL: URL(string: "https://github.com/login/device")!, expiresAt: Date().addingTimeInterval(100), interval: 5)
    let denied = try OAuthFixtureTransport([["error":"access_denied"]])
    await #expect(throws: GitFailure.self) { _ = try await OAuthDeviceAuthorization(transport: denied).wait(challenge, configuration: config, sleep: { _ in }) }
    let cancelled = try OAuthFixtureTransport([])
    await #expect(throws: CancellationError.self) { _ = try await OAuthDeviceAuthorization(transport: cancelled).wait(challenge, configuration: config, sleep: { _ in throw CancellationError() }) }
    #expect(await cancelled.requests.isEmpty)
    let expired = OAuthDeviceChallenge(deviceCode: "fixture", userCode: "ABCD-EFGH", verificationURL: challenge.verificationURL, expiresAt: Date().addingTimeInterval(-1), interval: 5)
    await #expect(throws: GitFailure.self) { _ = try await OAuthDeviceAuthorization(transport: cancelled).wait(expired, configuration: config) }
    #expect(await cancelled.requests.isEmpty)
}

@Test func gitlabCodeExchangeBindsVerifierRedirectAndClientWithoutSecret() async throws {
    let config = try OAuthConfiguration(provider: .gitlab, host: "gitlab.com", clientID: "fixture-client")
    let pkce = try OAuthPKCE(), transport = try OAuthFixtureTransport([grantObject()])
    let callback = URL(string: config.callback.absoluteString + "?state=" + pkce.state + "&code=fixture-code")!
    _ = try await OAuthCodeAuthorization(transport: transport).exchange(callback: callback, pkce: pkce, configuration: config)
    let request = try #require(await transport.requests.first)
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    #expect(request.url == config.tokenURL && body.contains("code_verifier=" + pkce.verifier) && body.contains("redirect_uri=gitpico%3A%2F%2Foauth%2Fgitlab%2Fcallback") && !body.contains("client_secret"))
}

@Test func concurrentOAuthRenewalRotatesOnceAndPreservesAccountIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-OAuth-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 2_000_000_000), id = UUID(), vault = OAuthFixtureVault()
    let config = try OAuthConfiguration(provider: .gitlab, host: "gitlab.com", clientID: "fixture-client")
    let old = GitStoredCredential(host: "gitlab.com", username: "fixture", secret: "old-access", oauth: OAuthAuthorization(configuration: config, refreshToken: "old-refresh", expiresAt: now.addingTimeInterval(-1), refreshExpiresAt: nil, scopes: config.scopes))
    try vault.save(old, id: id)
    let transport = try OAuthFixtureTransport([grantObject()], delay: .milliseconds(50))
    let first = OAuthCredentialRefresher(storage: vault, transport: transport, lockDirectory: directory)
    let second = OAuthCredentialRefresher(storage: vault, transport: transport, lockDirectory: directory)
    async let a = first.credential(id, now: now)
    async let b = second.credential(id, now: now)
    let pair = try await (a, b)
    #expect(pair.0.secret == "new-fixture-access" && pair.1.secret == pair.0.secret)
    #expect(try vault.read(id).oauth?.refreshToken == "new-fixture-refresh" && vault.read(id).username == "fixture")
    let requests = await transport.requests
    #expect(requests.count == 1)
    #expect(String(decoding: requests[0].httpBody ?? Data(), as: UTF8.self).contains("refresh_token=old-refresh"))
    let answer = GitCredentialHelper.response(operation: "get", input: "protocol=https\nhost=gitlab.com\n", credential: pair.0, expectedHost: "gitlab.com")
    #expect(answer.contains("password=new-fixture-access") && !answer.contains("new-fixture-refresh"))
    let generic = GitCredentialHelper.response(operation: "get", input: "protocol=https\nhost=gitlab.com\nusername=oauth2\n", credential: pair.0, expectedHost: "gitlab.com")
    #expect(generic.contains("username=oauth2\npassword=new-fixture-access"))
}

@Test func rejectedOAuthRenewalKeepsCredentialAndPersonalTokensNeverUseOAuthTransport() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-OAuth-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(), id = UUID(), vault = OAuthFixtureVault(), config = try OAuthConfiguration(provider: .github, host: "github.com", clientID: "fixture")
    let oauth = OAuthAuthorization(configuration: config, refreshToken: "old-refresh", expiresAt: now.addingTimeInterval(-1), refreshExpiresAt: nil, scopes: ["repo"])
    try vault.save(GitStoredCredential(host: "github.com", username: "fixture", secret: "old-access", oauth: oauth), id: id)
    let denied = try OAuthFixtureTransport([["error":"invalid_grant"]], status: 400)
    let manager = OAuthCredentialRefresher(storage: vault, transport: denied, lockDirectory: directory)
    await #expect(throws: GitFailure.self) { _ = try await manager.credential(id, now: now) }
    #expect(try vault.read(id).secret == "old-access")
    let patID = UUID(); try vault.save(GitStoredCredential(host: "github.com", username: "fixture", secret: "pat-fixture"), id: patID)
    #expect(try await manager.credential(patID).secret == "pat-fixture")
    #expect(await denied.requests.count == 1)
    let legacy = Data("{\"host\":\"github.com\",\"username\":\"fixture\",\"secret\":\"legacy\"}".utf8)
    #expect(try JSONDecoder().decode(GitStoredCredential.self, from: legacy).oauth == nil)
}

@Test func oauthRedactionIncludesRefreshTokensVerifiersAndGitLabOAuthSecrets() {
    let hex = String(repeating: "a1", count: 32)
    let text = "refresh_token=fixture-refresh code_verifier=fixture-verifier device_code=fixture-device " + hex
    let clean = GitLogRedaction.clean(text)
    for value in ["fixture-refresh", "fixture-verifier", "fixture-device", hex] { #expect(!clean.contains(value)) }
}

@Test func oauthRenewalFinishesSavingRotatedTokensAfterCallerCancellation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-OAuth-cancel-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID(), vault = OAuthFixtureVault(), now = Date()
    let config = try OAuthConfiguration(provider: .gitlab, host: "gitlab.com", clientID: "fixture")
    let auth = OAuthAuthorization(configuration: config, refreshToken: "old-refresh", expiresAt: now.addingTimeInterval(-1), refreshExpiresAt: nil, scopes: config.scopes)
    try vault.save(GitStoredCredential(host: "gitlab.com", username: "fixture", secret: "old-access", oauth: auth), id: id)
    let transport = try OAuthFixtureTransport([grantObject()], delay: .milliseconds(80))
    let manager = OAuthCredentialRefresher(storage: vault, transport: transport, lockDirectory: directory)
    let job = Task { try await manager.credential(id, now: now) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await transport.requests.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
    job.cancel()
    #expect(try await job.value.secret == "new-fixture-access")
    #expect(try vault.read(id).oauth?.refreshToken == "new-fixture-refresh")
}
