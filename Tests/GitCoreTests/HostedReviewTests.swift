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
@Test func hostedReviewsUseExactHostCredentialsEncodedProjectsAndReviewedHead() async throws {
    let project = try HostedRepository(remote: "git@git.example.invalid:team/sub/project.git", provider: .gitlab)
    let item: [String: Any] = ["iid": 3, "title": "Review", "description": "Body", "author": ["username": "reviewer"], "source_branch": "feature", "target_branch": "main", "sha": "abc123", "state": "opened", "web_url": "https://git.example.invalid/team/sub/project/-/merge_requests/3"]
    let transport = try ReviewTransport([reviewResponse([item]), reviewResponse(item, status: 201), reviewResponse(item.merging(["state": "merged"]) { _, new in new })])
    let client = try HostedReviewClient(repository: project, credential: GitStoredCredential(host: project.host, username: "fixture", secret: "fixture-token"), transport: transport)
    let review = try #require(try await client.list().first)
    #expect(review.number == 3 && review.head == "abc123")
    _ = try await client.create(title: "Title", body: "Body", source: "feature", target: "main")
    try await client.merge(review, squash: true)
    let requests = await transport.requests
    #expect(requests[0].url?.absoluteString.contains("projects/team%2Fsub%2Fproject/merge_requests") == true)
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "fixture-token" })
    let mergeBody = try #require(requests.last?.httpBody)
    let merge = try #require(try JSONSerialization.jsonObject(with: mergeBody) as? [String: Any])
    #expect(merge["sha"] as? String == "abc123" && merge["squash"] as? Bool == true)
    #expect(merge["should_remove_source_branch"] as? Bool == false)
    #expect(throws: GitFailure.self) { try HostedReviewClient(repository: project, credential: GitStoredCredential(host: "other.invalid", username: "fixture", secret: "fixture-token"), transport: transport) }
}

@Test func githubReviewCreationAndApprovalKeepDraftAndCommitGuards() async throws {
    let project = try HostedRepository(remote: "https://github.com/example/fixture.git", provider: .github)
    let item: [String: Any] = ["number": 2, "title": "Review", "user": ["login": "reviewer"], "head": ["ref": "feature", "sha": "abc123"], "base": ["ref": "main"], "state": "open", "html_url": "https://github.com/example/fixture/pull/2"]
    let transport = try ReviewTransport([reviewResponse(item, status: 201), reviewResponse([:]), reviewResponse(["merged": false])])
    let client = try HostedReviewClient(repository: project, credential: GitStoredCredential(host: "github.com", username: "fixture", secret: "fixture-token"), transport: transport)
    let review = try await client.create(title: "Title", body: "Body", source: "feature", target: "main")
    try await client.approve(review, comment: "Needs a change", requestChanges: true)
    await #expect(throws: GitFailure.self) { try await client.merge(review, squash: false) }
    let requests = await transport.requests
    let creationBody = try #require(requests[0].httpBody), approvalBody = try #require(requests[1].httpBody)
    let creation = try #require(try JSONSerialization.jsonObject(with: creationBody) as? [String: Any])
    let approval = try #require(try JSONSerialization.jsonObject(with: approvalBody) as? [String: Any])
    #expect(creation["draft"] as? Bool == true)
    #expect(approval["commit_id"] as? String == "abc123" && approval["event"] as? String == "REQUEST_CHANGES")
    #expect(requests.allSatisfy { $0.url?.host == "api.github.com" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" })
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
