import Foundation

public struct OAuthHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}
public protocol OAuthHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse
}
public struct OAuthTransportFailure: LocalizedError, Sendable {
    public let retryable: Bool
    public let message: String
    public var errorDescription: String? { message }
    public init(retryable: Bool, message: String) { self.retryable = retryable; self.message = message }
}
public struct OAuthHTTPSClient: OAuthHTTPTransport {
    private let maximumResponseBytes: Int
    public init(maximumResponseBytes: Int = 131_072) { self.maximumResponseBytes = min(4 * 1024 * 1024, max(1, maximumResponseBytes)) }
    public func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        guard request.url?.scheme == "https", request.url?.user == nil, request.url?.password == nil else { throw GitFailure("OAuth requires a secure server URL.") }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: NoOAuthRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw GitFailure("The sign-in server returned an invalid response.") }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumResponseBytes else { throw GitFailure("The server response exceeded its size limit.") }
                data.append(byte)
            }
            return OAuthHTTPResponse(status: response.statusCode, data: data)
        } catch is CancellationError { throw CancellationError() }
        catch let failure as GitFailure { throw failure }
        catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            let code = (error as? URLError)?.code
            if code == .secureConnectionFailed || code == .serverCertificateUntrusted || code == .serverCertificateHasBadDate || code == .serverCertificateHasUnknownRoot {
                throw OAuthTransportFailure(retryable: false, message: "The secure connection failed. Check the server certificate, system date and proxy. Certificate validation remains enabled.")
            }
            throw OAuthTransportFailure(retryable: [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(code), message: "Could not reach the server. Check your network or proxy and try again.")
        }
    }
    private final class NoOAuthRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
}

public enum OAuthRequests {
    public static func form(_ url: URL, _ values: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("GitPico", forHTTPHeaderField: "User-Agent")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(values.map { $0.0.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
        return request
    }
    public static func object(_ response: OAuthHTTPResponse) throws -> [String: Any] {
        guard response.data.count <= 131_072, let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw GitFailure("The sign-in server returned an invalid response.") }
        return object
    }
    public static func grant(_ response: OAuthHTTPResponse, now: Date = Date(), previous: OAuthAuthorization? = nil) throws -> OAuthTokenGrant {
        let object = try object(response)
        guard (200..<300).contains(response.status), object["error"] == nil else { throw GitFailure("Authorization could not be completed or renewed. Sign in again; check the OAuth application settings if the problem continues.") }
        func secret(_ value: Any?) -> String? {
            guard let value = value as? String, !value.isEmpty, value.utf8.count < 16_384, !value.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
            return value
        }
        guard let access = secret(object["access_token"]), (object["token_type"] as? String)?.lowercased() == "bearer" else { throw GitFailure("The provider did not return a valid bearer token.") }
        if object["refresh_token"] != nil && secret(object["refresh_token"]) == nil { throw GitFailure("The provider returned an invalid refresh token.") }
        let refresh = secret(object["refresh_token"]) ?? previous?.refreshToken
        func expiration(_ key: String) throws -> Date? {
            guard let raw = object[key] else { return nil }
            let seconds = (raw as? NSNumber)?.doubleValue ?? Double(raw as? String ?? "") ?? .nan
            guard seconds.isFinite, seconds > 0, seconds <= 63_072_000 else { throw GitFailure("The provider returned an invalid token lifetime.") }
            return now.addingTimeInterval(seconds)
        }
        let expiry = try expiration("expires_in"), refreshExpiry = try expiration("refresh_token_expires_in")
        guard previous?.expiresAt == nil || expiry != nil else { throw GitFailure("The renewed token did not include its expiration.") }
        guard expiry == nil || refresh != nil else { throw GitFailure("The expiring token did not include a refresh token. Sign in again.") }
        let scopes: [String]
        if let value = object["scope"] as? String { scopes = value.split { $0 == "," || $0.isWhitespace }.map(String.init) }
        else if let value = object["scope"] as? [String] { scopes = value }
        else { scopes = previous?.scopes ?? [] }
        return OAuthTokenGrant(accessToken: access, refreshToken: refresh, expiresAt: expiry, refreshExpiresAt: refreshExpiry ?? previous?.refreshExpiresAt, scopes: scopes)
    }
}
