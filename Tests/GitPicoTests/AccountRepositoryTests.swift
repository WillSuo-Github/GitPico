import Foundation
import GitCore
import Testing
@testable import GitPico

private actor RepositoryPageTransport: OAuthHTTPTransport {
    private var pages: [OAuthHTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(_ pages: [OAuthHTTPResponse]) { self.pages = pages }

    func send(_ request: URLRequest) throws -> OAuthHTTPResponse {
        requests.append(request)
        guard !pages.isEmpty else { throw GitFailure("Unexpected repository request.") }
        return pages.removeFirst()
    }
}

private func profile(_ provider: HostingProvider, host: String? = nil) -> AuthenticationProfile {
    AuthenticationProfile(id: UUID(), provider: provider, host: host ?? "github.com", username: "alice")
}

private func credential(_ profile: AuthenticationProfile, oauth: OAuthAuthorization? = nil) -> GitStoredCredential {
    GitStoredCredential(host: profile.host, username: profile.username, secret: "fixture-token", oauth: oauth)
}

private func githubPage(_ id: Int, owner: String, host: String = "github.com", link: String? = nil) -> OAuthHTTPResponse {
    let json = """
    [{"id":\(id),"name":"App","full_name":"\(owner)/App","clone_url":"https://\(host)/\(owner)/App.git","private":true}]
    """
    return OAuthHTTPResponse(status: 200, data: Data(json.utf8), link: link)
}

@Test func accountRepositoriesLoadEveryGitHubPageIncludingPrivateOrgRepos() async throws {
    let account = profile(.github)
    let transport = RepositoryPageTransport([
        githubPage(1, owner: "alice", link: #"<https://api.github.com/user/repos?per_page=100&page=2>; rel="next", <https://api.github.com/user/repos?per_page=100&page=2>; rel="last""#),
        githubPage(2, owner: "team")
    ])
    let repositories = try await AccountRepositoryClient.list(account, credential: credential(account), transport: transport)
    #expect(repositories.map(\.fullName) == ["alice/App", "team/App"])
    #expect(repositories.filter { $0.isRestricted }.count == 2)
    #expect(repositories[1].cloneURL.absoluteString == "https://github.com/team/App.git")
    let requests = await transport.requests
    #expect(requests.map { $0.url?.host } == ["api.github.com", "api.github.com"])
    #expect(requests[1].url?.query?.contains("page=2") == true)
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" })
}

@Test func accountRepositoriesNeverSendTokenToUntrustedPageOrCloneHost() async throws {
    let account = profile(.github)
    let crossHost = RepositoryPageTransport([
        githubPage(1, owner: "alice", link: #"<https://other.example/user/repos?page=2>; rel="next""#)
    ])
    await #expect(throws: GitFailure.self) {
        try await AccountRepositoryClient.list(account, credential: credential(account), transport: crossHost)
    }
    #expect(await crossHost.requests.count == 1)

    let badClone = RepositoryPageTransport([githubPage(1, owner: "alice", host: "other.example")])
    await #expect(throws: GitFailure.self) {
        try await AccountRepositoryClient.list(account, credential: credential(account), transport: badClone)
    }
}

@Test func accountRepositoriesReadNestedGitLabProjectsAndDetectOldOAuthGrant() async throws {
    let account = profile(.gitlab, host: "gitlab.example:8443")
    let data = Data("""
        [{"id":42,"path":"app","path_with_namespace":"team/nested/app","http_url_to_repo":"https://gitlab.example:8443/team/nested/app.git","ssh_url_to_repo":"git@ssh.gitlab.example:team/nested/app.git","visibility":"internal"}]
        """.utf8)
    let transport = RepositoryPageTransport([
        OAuthHTTPResponse(status: 200, data: data, nextPage: "2"),
        OAuthHTTPResponse(status: 200, data: data)
    ])
    let repositories = try await AccountRepositoryClient.list(account, credential: credential(account), transport: transport)
    #expect(repositories.map(\.fullName) == ["team/nested/app"])
    #expect(repositories.first?.isRestricted == true)
    let sshKey = try #require(HostedRepositoryKey(remote: "ssh://git@ssh.gitlab.example/team/nested/app.git", provider: .gitlab))
    #expect(repositories.first?.keys.contains(sshKey) == true)
    let requests = await transport.requests
    #expect(requests.map { $0.url?.path } == ["/api/v4/projects", "/api/v4/projects"])
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "fixture-token" })
    #expect(requests[0].url?.query?.contains("membership=true") == true)
    #expect(requests[1].url?.query?.contains("page=2") == true)

    let config = try OAuthConfiguration(provider: .gitlab, host: account.host, clientID: "fixture")
    let authorization = OAuthAuthorization(configuration: config, refreshToken: nil, expiresAt: nil, refreshExpiresAt: nil, scopes: ["read_user", "write_repository"])
    let old = RepositoryPageTransport([])
    await #expect(throws: GitFailure.self) {
        try await AccountRepositoryClient.list(account, credential: credential(account, oauth: authorization), transport: old)
    }
    #expect(await old.requests.isEmpty)
}

@Test func accountRepositoriesMatchDisposableCheckoutsByRemoteAndIgnoreForkUpstream() async throws {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("GitPico-account-repos-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    func makeRepo(_ folder: String, remote: String) async throws -> URL {
        let url = directory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await GitProcess.run(["init", "--quiet"], at: url)
        _ = try await GitProcess.run(["remote", "add", "origin", remote], at: url)
        return url
    }
    let renamed = try await makeRepo("renamed-checkout", remote: "git@github.com:Team/App.git")
    let other = try await makeRepo("App", remote: "https://github.com/alice/App.git")
    _ = try await GitProcess.run(["remote", "add", "upstream", "https://github.com/team/App.git"], at: other)
    let altSSH = try await makeRepo("alternate", remote: "ssh://git@ssh.github.com:443/team/app.git")
    let nested = other.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let missing = directory.appendingPathComponent("missing")
    let index = await LocalHostedRepositoryIndex.load(paths: [renamed.path, other.path, altSSH.path, nested.path, missing.path], provider: .github)
    let teamKey = try #require(HostedRepositoryKey(remote: "https://github.com/team/app.git", provider: .github))
    let forkKey = try #require(HostedRepositoryKey(remote: "https://github.com/alice/app.git", provider: .github))
    #expect(index[teamKey] == [renamed.path, altSSH.path])
    #expect(index[forkKey] == [other.path])

    let (root, keys) = try await LocalHostedRepositoryIndex.keys(at: nested, provider: .github, requireExactRoot: false)
    #expect(root.path == other.path)
    #expect(keys == [forkKey])
}
