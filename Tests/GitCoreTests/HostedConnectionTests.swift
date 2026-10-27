import Foundation
import Testing
@testable import GitCore

private actor ReviewTransport: OAuthHTTPTransport {
    var responses: [OAuthHTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [OAuthHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw GitFailure("No fixture response") }
        return responses.removeFirst()
    }
}
private func reviewResponse(_ object: Any, status: Int = 200) throws -> OAuthHTTPResponse {
    OAuthHTTPResponse(status: status, data: try JSONSerialization.data(withJSONObject: object))
}
private actor TransientPollTransport: OAuthHTTPTransport {
    var attempts = 0
    let alwaysFail: Bool
    init(alwaysFail: Bool = false) { self.alwaysFail = alwaysFail }
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        attempts += 1
        if alwaysFail || attempts == 1 { throw OAuthTransportFailure(retryable: true, message: "Fixture offline") }
        return try reviewResponse(["access_token": "fixture-token", "token_type": "bearer", "scope": "repo read:user"])
    }
}
@Test func devicePollingRetriesTransientFailuresWithinABoundedBudget() async throws {
    let config = try OAuthConfiguration(provider: .github, host: "github.com", clientID: "fixture-client")
    let challenge = OAuthDeviceChallenge(deviceCode: "fixture", userCode: "FIXT-URES", verificationURL: URL(string: "https://github.com/login/device")!, expiresAt: Date().addingTimeInterval(600), interval: 5)
    let recovered = TransientPollTransport()
    _ = try await OAuthDeviceAuthorization(transport: recovered).wait(challenge, configuration: config, sleep: { _ in })
    #expect(await recovered.attempts == 2)
    let failed = TransientPollTransport(alwaysFail: true)
    await #expect(throws: OAuthTransportFailure.self) { try await OAuthDeviceAuthorization(transport: failed).wait(challenge, configuration: config, sleep: { _ in }) }
    #expect(await failed.attempts == 4)
}

@Test func privateGitHubUpdatesUseAuthenticatedAssetIDsAndRejectUnrelatedDownloads() async throws {
    let release: [String: Any] = ["draft": false, "prerelease": false, "tag_name": "build-20261026000000", "assets": [
        ["id": 10, "name": "appcast.xml", "browser_download_url": "https://other.invalid/feed"],
        ["id": 11, "name": "GitPico-20261026000000.zip"], ["id": 12, "name": "notes.html"]]]
    let transport = try ReviewTransport([reviewResponse(release)])
    let credential = GitStoredCredential(host: "github.com", username: "fixture", secret: "fixture-token")
    let client = GitHubReleaseFeedClient(transport: transport)
    let feed = try await client.latest(project: "example/private", credential: credential)
    #expect(feed.feedURL.absoluteString == "https://api.github.com/repos/example/private/releases/assets/10")
    #expect(feed.permits(URL(string: "https://api.github.com/repos/example/private/releases/assets/11")!))
    #expect(!feed.permits(feed.feedURL))
    #expect(!feed.permits(URL(string: "https://api.github.com/repos/example/private/releases/assets/12")!))
    #expect(!feed.permits(URL(string: "https://other.invalid/archive.zip")!))
    let requests = await transport.requests
    #expect(requests.count == 1 && requests[0].url?.host == "api.github.com")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    await #expect(throws: GitFailure.self) { try await client.latest(project: "../private", credential: credential) }
    await #expect(throws: GitFailure.self) { try await client.latest(project: "example/private", credential: GitStoredCredential(host: "other.invalid", username: "fixture", secret: "fixture-token")) }
    #expect(await transport.requests.count == 1)
    let denied = try ReviewTransport([reviewResponse([:], status: 404), reviewResponse(release.merging(["draft": true]) { _, new in new }), reviewResponse(release.merging(["assets": [["id": 10, "name": "appcast.xml"]]]) { _, new in new })])
    let rejected = GitHubReleaseFeedClient(transport: denied)
    for _ in 0..<3 { await #expect(throws: GitFailure.self) { try await rejected.latest(project: "example/private", credential: credential) } }
}

@Test func privateFeedResolvesOnlyGitHubSignedCDNDownloadsWithoutFollowingAccountRedirects() async throws {
    let credential = GitStoredCredential(host: "github.com", username: "fixture", secret: "fixture-token")
    let api = URL(string: "https://api.github.com/repos/example/private/releases/assets/10")!
    let release = GitHubReleaseFeed(feedURL: api, assets: [], releaseURL: URL(string: "https://github.com/example/private/releases")!, tag: "fixture")
    let destination = URL(string: "https://release-assets.githubusercontent.com/fixture/appcast.xml?fixture=opaque")!
    let transport = ReviewTransport([OAuthHTTPResponse(status: 302, data: Data(), redirectURL: destination)])
    let resolved = try await GitHubReleaseFeedClient(transport: transport).feedDownloadURL(release, credential: credential)
    #expect(resolved == destination)
    let requests = await transport.requests
    #expect(requests.count == 1 && requests[0].url == api)
    #expect(requests[0].value(forHTTPHeaderField: "Accept") == "application/octet-stream")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    for value in ["http://release-assets.githubusercontent.com/feed", "https://other.invalid/feed", "https://release-assets.githubusercontent.com.other.invalid/feed", "https://user@release-assets.githubusercontent.com/feed"] {
        let denied = ReviewTransport([OAuthHTTPResponse(status: 302, data: Data(), redirectURL: URL(string: value))])
        await #expect(throws: GitFailure.self) { try await GitHubReleaseFeedClient(transport: denied).feedDownloadURL(release, credential: credential) }
    }
    let metadata = ReviewTransport([OAuthHTTPResponse(status: 200, data: Data("{}".utf8))])
    await #expect(throws: GitFailure.self) { try await GitHubReleaseFeedClient(transport: metadata).feedDownloadURL(release, credential: credential) }
}

@Test func publicGitHubUpdatesResolveWithoutAuthorizationOrCookiesAndKeepAssetValidation() async throws {
    let object: [String: Any] = ["draft": false, "prerelease": false, "tag_name": "build-20261027000000", "assets": [
        ["id": 10, "name": "appcast.xml", "browser_download_url": "https://other.invalid/feed"],
        ["id": 11, "name": "GitPico-20261027000000.zip"]]]
    let destination = URL(string: "https://release-assets.githubusercontent.com/fixture/appcast.xml?signature=fixture")!
    let transport = try ReviewTransport([reviewResponse(object), OAuthHTTPResponse(status: 302, data: Data(), redirectURL: destination)])
    let client = GitHubReleaseFeedClient(transport: transport)
    let release = try await client.latest(project: "example/public")
    #expect(try await client.feedDownloadURL(release) == destination)
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil })
    #expect(requests[1].value(forHTTPHeaderField: "Accept") == "application/octet-stream")
    #expect(release.permits(URL(string: "https://api.github.com/repos/example/public/releases/assets/11")!))
    #expect(!release.permits(URL(string: "https://api.github.com/repos/example/other/releases/assets/11")!))
    #expect(!release.permits(URL(string: "https://other.invalid/archive.zip")!))
    let archive = NSMutableURLRequest(url: try #require(release.assets.first))
    archive.setValue("Bearer stale-account", forHTTPHeaderField: "Authorization")
    archive.setValue("stale-cookie", forHTTPHeaderField: "Cookie")
    try release.configurePublicDownload(archive)
    #expect(archive.value(forHTTPHeaderField: "Authorization") == nil && archive.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(!archive.httpShouldHandleCookies && archive.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
    let unrelated = NSMutableURLRequest(url: URL(string: "https://other.invalid/archive.zip")!)
    unrelated.setValue("Bearer stale-account", forHTTPHeaderField: "Authorization")
    #expect(throws: GitFailure.self) { try release.configurePublicDownload(unrelated) }
    #expect(unrelated.value(forHTTPHeaderField: "Authorization") == nil)
    await #expect(throws: GitFailure.self) { try await client.latest(project: "example/../public") }
    let invalid = GitHubReleaseFeed(feedURL: URL(string: "https://other.invalid/appcast.xml")!, assets: [], releaseURL: release.releaseURL, tag: release.tag)
    await #expect(throws: GitFailure.self) { try await client.feedDownloadURL(invalid) }
    #expect(await transport.requests.count == 2)
}
