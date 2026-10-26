import Foundation
import Darwin
import GitCore
import Observation

enum HostingProvider: String, Codable, CaseIterable, Sendable { case github = "GitHub", gitlab = "GitLab", generic = "Other HTTPS" }
struct AuthenticationProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let provider: HostingProvider
    let host: String
    let username: String
    var method: AuthenticationMethod? = nil
    var isOAuth: Bool { method == .oauth }
    var label: String { provider.rawValue + " · " + username + " @ " + host + (isOAuth ? " (OAuth)" : "") }
}
enum AuthenticationMethod: String, Codable, Sendable { case oauth }
protocol CredentialStoring: Sendable {
    func save(_ value: GitStoredCredential, id: UUID) throws
    func read(_ id: UUID) throws -> GitStoredCredential
    func remove(_ id: UUID) throws
}
struct SystemCredentialVault: CredentialStoring {
    func save(_ value: GitStoredCredential, id: UUID) throws { try GitCredentialVault.save(value, id: id) }
    func read(_ id: UUID) throws -> GitStoredCredential { try GitCredentialVault.read(id) }
    func remove(_ id: UUID) throws { try GitCredentialVault.remove(id) }
}

@MainActor @Observable final class AuthenticationStore {
    private struct Document: Codable { var profiles: [AuthenticationProfile] = []; var assignments: [String: UUID] = [:] }
    private(set) var profiles: [AuthenticationProfile] = []
    private(set) var assignments: [String: UUID] = [:]
    var error: String?
    private(set) var revision = 0
    let file: URL
    @ObservationIgnored let vault: any CredentialStoring
    @ObservationIgnored private var diskData: Data?
    @ObservationIgnored private var loaded = false
    init(file: URL, vault: any CredentialStoring = SystemCredentialVault()) {
        self.file = file; self.vault = vault
        reload()
    }
    func reload() {
        loaded = false
        do {
            let data = try read()
            let document = try data.map { try JSONDecoder().decode(Document.self, from: $0) } ?? Document()
            guard document.profiles.count <= 100, document.assignments.count <= 5000, Set(document.profiles.map(\.id)).count == document.profiles.count else { throw GitFailure("Authentication settings exceed their limits.") }
            for profile in document.profiles { _ = try Self.host(profile.host) }
            profiles = document.profiles; assignments = document.assignments; diskData = data; loaded = true; error = nil; revision += 1
        } catch { self.error = error.localizedDescription }
    }
    static func host(_ value: String) throws -> String {
        guard let components = URLComponents(string: "https://" + value), let host = components.host, !host.isEmpty, components.user == nil, components.password == nil, components.path.isEmpty, components.query == nil, components.fragment == nil, !value.contains(where: { $0.isWhitespace }), !value.contains("\n") else { throw GitFailure("Enter only a hostname and optional port, without a URL, path or credentials.") }
        return host.lowercased() + (components.port.map { ":\($0)" } ?? "")
    }
    func profile(for root: URL) -> AuthenticationProfile? { profiles.first { $0.id == assignments[root.path] } }
    @discardableResult func add(provider: HostingProvider, host: String, username: String, token: String, for root: URL?) throws -> AuthenticationProfile {
        guard loaded else { throw GitFailure("Reload authentication settings before connecting an account.") }
        let profile = AuthenticationProfile(id: UUID(), provider: provider, host: try Self.host(host), username: username.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !profile.username.isEmpty, !profile.username.contains(where: { $0.isNewline }), !token.isEmpty else { throw GitFailure("Enter your account username and personal access token.") }
        let credential = GitStoredCredential(host: profile.host, username: profile.username, secret: token)
        try vault.save(credential, id: profile.id)
        var values = assignments
        if let root { values[root.path] = profile.id }
        do { try persist(profiles + [profile], assignments: values) }
        catch { try? vault.remove(profile.id); throw error }
        return profile
    }
    func assign(_ id: UUID?, to root: URL) throws {
        guard id == nil || profiles.contains(where: { $0.id == id }) else { throw GitFailure("Choose an existing authentication profile.") }
        var values = assignments; values[root.path] = id
        try persist(profiles, assignments: values)
    }
    func replaceToken(_ profile: AuthenticationProfile, token: String) throws {
        guard !profile.isOAuth else { throw GitFailure("Use Sign In Again to renew an OAuth account.") }
        guard loaded, profiles.contains(profile), try read() == diskData else { throw GitFailure("Reload authentication settings before updating this account.") }
        guard !token.isEmpty, !token.contains(where: { $0.isNewline || $0 == "\0" }), token.utf8.count < 16_384 else { throw GitFailure("Enter a token without line breaks.") }
        try vault.save(GitStoredCredential(host: profile.host, username: profile.username, secret: token), id: profile.id)
        revision += 1
    }
    @discardableResult func completeOAuth(_ configuration: OAuthConfiguration, grant: OAuthTokenGrant, username: String, root: URL?, reconnecting: AuthenticationProfile? = nil) throws -> AuthenticationProfile {
        guard loaded else { throw GitFailure("Reload authentication settings before signing in.") }
        try grant.requireRepositoryScopes(configuration.provider)
        let provider: HostingProvider = configuration.provider == .github ? .github : .gitlab
        guard !username.isEmpty, !username.contains(where: { $0.isNewline || $0 == "\0" }) else { throw GitFailure("The provider returned an invalid account name.") }
        if let reconnecting {
            guard profiles.contains(reconnecting), reconnecting.isOAuth, reconnecting.provider == provider, reconnecting.host == configuration.host, reconnecting.username == username, try read() == diskData else { throw GitFailure("The signed-in account differs from the account being renewed, or account settings changed. Add it as a separate account or reload settings.") }
            try vault.save(GitStoredCredential(host: configuration.host, username: username, secret: grant.accessToken, oauth: grant.authorization(configuration)), id: reconnecting.id)
            revision += 1
            return reconnecting
        }
        let profile = AuthenticationProfile(id: UUID(), provider: provider, host: configuration.host, username: username, method: .oauth)
        let credential = GitStoredCredential(host: configuration.host, username: username, secret: grant.accessToken, oauth: grant.authorization(configuration))
        try vault.save(credential, id: profile.id)
        var values = assignments; if let root { values[root.path] = profile.id }
        do { try persist(profiles + [profile], assignments: values) }
        catch { try? vault.remove(profile.id); throw error }
        return profile
    }
    func remove(_ profile: AuthenticationProfile) throws {
        let saved = try vault.read(profile.id)
        try vault.remove(profile.id)
        do { try persist(profiles.filter { $0.id != profile.id }, assignments: assignments.filter { $0.value != profile.id }) }
        catch { try? vault.save(saved, id: profile.id); throw error }
    }
    private func read() throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576 else { throw GitFailure("Authentication settings are not a regular file under 1 MB.") }
        return try Data(contentsOf: file)
    }
    private func persist(_ profiles: [AuthenticationProfile], assignments: [String: UUID]) throws {
        guard loaded, profiles.count <= 100, assignments.count <= 5000 else { throw GitFailure("Reload authentication settings before saving, or remove unused profiles.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(file.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw GitFailure("Cannot lock authentication settings.") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw GitFailure("Authentication settings are being saved by another process.") }
        defer { flock(fd, LOCK_UN) }
        guard try read() == diskData else { throw GitFailure("Authentication settings changed in another process. Reload them before editing.") }
        let data = try JSONEncoder().encode(Document(profiles: profiles, assignments: assignments))
        try data.write(to: file, options: .atomic)
        self.profiles = profiles; self.assignments = assignments; diskData = data; revision += 1; error = nil
    }
}

struct HostingAccountVerification: Sendable { let login: String; let description: String }
enum HostingAccountClient {
    static func request(_ profile: AuthenticationProfile, credential: GitStoredCredential) throws -> URLRequest {
        guard profile.host == credential.host, profile.provider != .generic else { throw GitFailure("Use Test Remote to verify this HTTPS server through Git.") }
        let base = "https://" + profile.host
        let publicGitHub = ["github.com", "github.com:443"].contains(profile.host)
        let endpoint = profile.provider == .github ? (publicGitHub ? "https://api.github.com/user" : base + "/api/v3/user") : base + "/api/v4/user"
        guard let url = URL(string: endpoint) else { throw GitFailure("Invalid hosting API URL.") }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        if profile.provider == .gitlab && credential.oauth == nil { request.setValue(credential.secret, forHTTPHeaderField: "PRIVATE-TOKEN") }
        else { request.setValue("Bearer " + credential.secret, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GitPico", forHTTPHeaderField: "User-Agent")
        return request
    }
    static func verify(_ profile: AuthenticationProfile, credential: GitStoredCredential) async throws -> HostingAccountVerification {
        let request = try request(profile, credential: credential)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoCredentialRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw GitFailure("Account verification failed. Check the token, server and account permissions.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw GitFailure("The hosting API response exceeds 1 MB.") }
            data.append(byte)
        }
        return try account(data)
    }
    static func account(_ data: Data) throws -> HostingAccountVerification {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let login = (object["login"] ?? object["username"]) as? String else { throw GitFailure("The server did not return a recognizable account.") }
        return HostingAccountVerification(login: login, description: "Account verified. Repository permissions are checked separately by Test Remote.")
    }
    private final class NoCredentialRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
