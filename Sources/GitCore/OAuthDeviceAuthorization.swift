import Foundation

public struct OAuthDeviceChallenge: Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    public let interval: TimeInterval
}

public struct OAuthDeviceAuthorization: Sendable {
    let transport: any OAuthHTTPTransport
    public init(transport: any OAuthHTTPTransport = OAuthHTTPSClient()) { self.transport = transport }
    public func start(_ configuration: OAuthConfiguration, now: Date = Date()) async throws -> OAuthDeviceChallenge {
        guard configuration.provider == .github else { throw GitFailure("Use browser sign-in for GitLab.") }
        let response = try await transport.send(OAuthRequests.form(URL(string: "https://" + configuration.host + "/login/device/code")!, [("client_id", configuration.clientID), ("scope", configuration.scopes.joined(separator: " "))]))
        let object = try OAuthRequests.object(response)
        guard response.status == 200, let device = object["device_code"] as? String, !device.isEmpty, device.utf8.count <= 4096,
              let user = object["user_code"] as? String, (4...32).contains(user.count), user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              let raw = object["verification_uri"] as? String, let url = URL(string: raw), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host?.lowercased() == URL(string: "https://" + configuration.host)?.host?.lowercased(), parts.port == URL(string: "https://" + configuration.host)?.port, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil, parts.path == "/login/device",
              let expires = object["expires_in"] as? Double, expires > 0, expires <= 1800,
              let interval = object["interval"] as? Double, interval > 0, interval <= 60 else { throw GitFailure("Device sign-in could not start. Check that Device Flow is enabled for this OAuth application.") }
        return OAuthDeviceChallenge(deviceCode: device, userCode: user, verificationURL: url, expiresAt: now.addingTimeInterval(expires), interval: max(5, interval))
    }
    public func wait(_ challenge: OAuthDeviceChallenge, configuration: OAuthConfiguration, now: @Sendable () -> Date = { Date() }, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws -> OAuthTokenGrant {
        var interval = challenge.interval
        while now() < challenge.expiresAt {
            try Task.checkCancellation()
            try await sleep(min(interval, max(0, challenge.expiresAt.timeIntervalSince(now()))))
            try Task.checkCancellation()
            guard now() < challenge.expiresAt else { break }
            let response = try await transport.send(OAuthRequests.form(configuration.tokenURL, [("client_id", configuration.clientID), ("device_code", challenge.deviceCode), ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")]))
            let object = try OAuthRequests.object(response)
            switch object["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval = max(interval + 5, (object["interval"] as? Double) ?? 0); continue
            case "access_denied": throw GitFailure("Authorization was declined. No account was saved.")
            case "expired_token", "token_expired": throw GitFailure("The sign-in code expired. Start sign-in again.")
            case nil: return try OAuthRequests.grant(response, now: now())
            default: throw GitFailure("Device authorization failed. Check the OAuth Client ID and Device Flow settings, then sign in again.")
            }
        }
        throw GitFailure("The sign-in code expired. Start sign-in again.")
    }
}

public struct OAuthCodeAuthorization: Sendable {
    let transport: any OAuthHTTPTransport
    public init(transport: any OAuthHTTPTransport = OAuthHTTPSClient()) { self.transport = transport }
    public func exchange(callback: URL, pkce: OAuthPKCE, configuration: OAuthConfiguration) async throws -> OAuthTokenGrant {
        guard configuration.provider == .gitlab else { throw GitFailure("Use device sign-in for GitHub.") }
        let code = try pkce.code(from: callback, configuration: configuration)
        let response = try await transport.send(OAuthRequests.form(configuration.tokenURL, [("client_id", configuration.clientID), ("code", code), ("grant_type", "authorization_code"), ("redirect_uri", configuration.callback.absoluteString), ("code_verifier", pkce.verifier)]))
        try Task.checkCancellation()
        return try OAuthRequests.grant(response)
    }
}
