import Darwin
import Foundation
import Synchronization

public protocol OAuthCredentialStorage: Sendable {
    func read(_ id: UUID) throws -> GitStoredCredential
    func save(_ credential: GitStoredCredential, id: UUID) throws
}
public struct OAuthKeychainStorage: OAuthCredentialStorage {
    public init() {}
    public func read(_ id: UUID) throws -> GitStoredCredential { try GitCredentialVault.read(id) }
    public func save(_ credential: GitStoredCredential, id: UUID) throws { try GitCredentialVault.save(credential, id: id) }
}

public actor OAuthCredentialRefresher {
    public static let shared = OAuthCredentialRefresher()
    let storage: any OAuthCredentialStorage
    let transport: any OAuthHTTPTransport
    let directory: URL
    public init(storage: any OAuthCredentialStorage = OAuthKeychainStorage(), transport: any OAuthHTTPTransport = OAuthHTTPSClient(), lockDirectory: URL? = nil) {
        self.storage = storage; self.transport = transport
        directory = lockDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GitPico/credential-locks")
    }
    public func credential(_ id: UUID, now: Date = Date()) async throws -> GitStoredCredential {
        let original = try storage.read(id)
        guard original.oauth?.needsRefresh(at: now) == true else { return original }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else { throw GitFailure("OAuth renewal storage is unavailable. Sign in again.") }
        let descriptor = Darwin.open(directory.appendingPathComponent(id.uuidString).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw GitFailure("OAuth renewal could not be locked. Try again.") }
        defer { Darwin.close(descriptor) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard ContinuousClock.now < deadline else { throw GitFailure("Another process is renewing this account. Try again.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { flock(descriptor, LOCK_UN) }
        // A sibling window/helper may have rotated the token while this request waited.
        let current = try storage.read(id)
        guard let authorization = current.oauth, authorization.needsRefresh(at: now) else { return current }
        let config = try OAuthConfiguration(provider: authorization.configuration.provider, host: current.host, clientID: authorization.configuration.clientID)
        guard config == authorization.configuration, let refresh = authorization.refreshToken, !refresh.isEmpty,
              authorization.refreshExpiresAt.map({ $0 > now }) ?? true else { throw GitFailure("This account authorization expired. Sign in again in Authentication.") }
        var values = [("client_id", config.clientID), ("grant_type", "refresh_token"), ("refresh_token", refresh)]
        if config.provider == .gitlab { values.append(("redirect_uri", config.callback.absoluteString)) }
        let request = OAuthRequests.form(config.tokenURL, values), transport = transport
        let response = try await Task.detached { try await transport.send(request) }.value
        // Once sent, finish saving a rotated token even when the requesting view goes away.
        let grant = try OAuthRequests.grant(response, now: now, previous: authorization)
        try grant.requireRepositoryScopes(config.provider)
        let updated = GitStoredCredential(host: current.host, username: current.username, secret: grant.accessToken, oauth: grant.authorization(config))
        guard try storage.read(id).secret == current.secret else { throw GitFailure("This account changed while it was being renewed. Retry with the current account.") }
        do { try storage.save(updated, id: id) }
        catch { throw GitFailure("Authorization renewed, but Keychain could not save the new token. Unlock Keychain and sign in again.") }
        return updated
    }
    public nonisolated static func forGit(_ id: UUID) throws -> GitStoredCredential {
        let value = try GitCredentialVault.read(id)
        guard value.oauth?.needsRefresh(at: Date()) == true else { return value }
        let result = Mutex<Result<GitStoredCredential, Error>?>(nil), completion = DispatchSemaphore(value: 0)
        Task.detached {
            do { let value = try await shared.credential(id); result.withLock { $0 = .success(value) } }
            catch { result.withLock { $0 = .failure(error) } }
            completion.signal()
        }
        guard completion.wait(timeout: .now() + 65) == .success, let value = result.withLock({ $0 }) else { throw GitFailure("OAuth renewal timed out. Try again or sign in again in Authentication.") }
        return try value.get()
    }
}
