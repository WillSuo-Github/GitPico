import CryptoKit
import Foundation
import Security

public enum OAuthProvider: String, Codable, Sendable, CaseIterable { case github, gitlab }

public struct OAuthConfiguration: Codable, Equatable, Sendable {
    public let provider: OAuthProvider
    public let host: String
    public let clientID: String
    public var apiAccess: Bool? = nil
    public init(provider: OAuthProvider, host: String, clientID: String, apiAccess: Bool = false) throws {
        guard let url = URLComponents(string: "https://" + host), let hostname = url.host, !hostname.isEmpty,
              url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil,
              !host.contains(where: { $0.isWhitespace || $0 == "\0" }),
              !clientID.isEmpty, clientID.utf8.count <= 256, !clientID.contains(where: { $0.isWhitespace || $0 == "\0" }) else { throw GitFailure("Enter a valid OAuth server and Client ID.") }
        self.provider = provider; self.host = host.lowercased(); self.clientID = clientID; self.apiAccess = apiAccess ? true : nil
    }
    public var callback: URL { URL(string: "gitpico://oauth/" + provider.rawValue + "/callback")! }
    public var tokenURL: URL { URL(string: "https://" + host + (provider == .github ? "/login/oauth/access_token" : "/oauth/token"))! }
    public var scopes: [String] { provider == .github ? ["repo", "read:user", "offline_access"] : ["read_user", "write_repository"] + (apiAccess == true ? ["api"] : []) }
}

public struct OAuthAuthorization: Codable, Sendable {
    public let configuration: OAuthConfiguration
    public let refreshToken: String?
    public let expiresAt: Date?
    public let refreshExpiresAt: Date?
    public let scopes: [String]
    public init(configuration: OAuthConfiguration, refreshToken: String?, expiresAt: Date?, refreshExpiresAt: Date?, scopes: [String]) {
        self.configuration = configuration; self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.refreshExpiresAt = refreshExpiresAt; self.scopes = scopes
    }
    public func needsRefresh(at date: Date) -> Bool { expiresAt.map { $0.timeIntervalSince(date) <= 60 } ?? false }
}

public struct OAuthTokenGrant: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let refreshExpiresAt: Date?
    public let scopes: [String]
    public func authorization(_ configuration: OAuthConfiguration) -> OAuthAuthorization {
        OAuthAuthorization(configuration: configuration, refreshToken: refreshToken, expiresAt: expiresAt, refreshExpiresAt: refreshExpiresAt, scopes: scopes)
    }
    public func requireRepositoryScopes(_ provider: OAuthProvider) throws {
        let values = Set(scopes)
        guard provider == .github ? values.contains("repo") : values.contains("api") || values.contains("read_user") && values.contains("write_repository") else { throw GitFailure("The authorization did not grant the requested repository permissions. Sign in again and review the requested access.") }
    }
}

public struct OAuthPKCE: Sendable {
    public let state: String
    public let verifier: String
    public var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public init() throws { state = try Self.random(); verifier = try Self.random() }
    public init(state: String, verifier: String) { self.state = state; self.verifier = verifier }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GitFailure("Could not create a secure sign-in request.") }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    public func authorizationURL(_ configuration: OAuthConfiguration) throws -> URL {
        guard configuration.provider == .gitlab else { throw GitFailure("GitHub uses device authorization in GitPico.") }
        var url = URLComponents(string: "https://" + configuration.host + "/oauth/authorize")!
        url.queryItems = [URLQueryItem(name: "client_id", value: configuration.clientID), URLQueryItem(name: "redirect_uri", value: configuration.callback.absoluteString), URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "state", value: state), URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")), URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256")]
        return url.url!
    }
    public func code(from callback: URL, configuration: OAuthConfiguration) throws -> String {
        guard let value = URLComponents(url: callback, resolvingAgainstBaseURL: false), value.scheme == configuration.callback.scheme, value.host == configuration.callback.host, value.path == configuration.callback.path, value.user == nil, value.password == nil, value.port == nil, value.fragment == nil else { throw GitFailure("The sign-in callback did not match this application.") }
        let items = value.queryItems ?? []
        func single(_ key: String) -> String? { let matches = items.filter { $0.name == key }; return matches.count == 1 ? matches.first?.value : nil }
        guard single("state") == state, !state.isEmpty else { throw GitFailure("The sign-in state did not match. Start a new sign-in.") }
        if items.contains(where: { $0.name == "error" }) { throw GitFailure("Authorization was declined or cancelled. No account was saved.") }
        guard let code = single("code"), !code.isEmpty, code.utf8.count <= 4096, !code.contains(where: { $0.isNewline || $0 == "\0" }) else { throw GitFailure("The provider did not return a valid authorization code.") }
        return code
    }
}
