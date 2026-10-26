import Foundation
import Testing
@testable import GitCore

private actor ThreadTransport: OAuthHTTPTransport {
    var replies: [OAuthHTTPResponse]
    var requests: [URLRequest] = []
    init(_ objects: [Any]) throws { replies = try objects.map { OAuthHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: $0)) } }
    func send(_ request: URLRequest) async throws -> OAuthHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw GitFailure("Unexpected fixture request") }
        return replies.removeFirst()
    }
}
private func threadReview(github: Bool, head: String = "abc123") -> [String: Any] {
    if github { return ["number": 2, "title": "Review", "head": ["ref": "feature", "sha": head], "base": ["ref": "main"], "state": "open", "html_url": "https://github.com/upstream/fixture/pull/2"] }
    return ["iid": 2, "title": "Review", "source_branch": "feature", "target_branch": "main", "sha": head, "state": "opened", "web_url": "https://gitlab.com/upstream/fixture/-/merge_requests/2", "diff_refs": ["base_sha": "base123", "start_sha": "start123", "head_sha": head]]
}
private func threadClient(_ transport: ThreadTransport, github: Bool = true) throws -> HostedReviewClient {
    let project = try HostedRepository(remote: github ? "https://github.com/upstream/fixture.git" : "https://gitlab.com/upstream/fixture.git", provider: github ? .github : .gitlab)
    return try HostedReviewClient(repository: project, credential: GitStoredCredential(host: project.host, username: "fixture", secret: "fixture-token"), transport: transport)
}
private func threadBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func forkReviewCreationUsesExplicitSourceAndTargetProjects() async throws {
    let github = try ThreadTransport([threadReview(github: true)])
    _ = try await threadClient(github).create(title: "Fork", body: "", source: "main", target: "main", sourceProject: "contributor/fixture")
    let githubRequest = try #require(await github.requests.first), githubBody = try threadBody(githubRequest)
    #expect(githubRequest.url?.path == "/repos/upstream/fixture/pulls")
    #expect(githubBody["head"] as? String == "contributor:main" && githubBody["head_repo"] as? String == "fixture")
    let gitlab = try ThreadTransport([["id": 123], threadReview(github: false)])
    _ = try await threadClient(gitlab, github: false).create(title: "Fork", body: "", source: "main", target: "main", sourceProject: "contributor/fixture")
    let requests = await gitlab.requests, gitlabBody = try threadBody(requests[1])
    #expect(requests[1].url?.absoluteString.contains("projects/contributor%2Ffixture/merge_requests") == true)
    #expect(gitlabBody["target_project_id"] as? Int == 123 && gitlabBody["source_branch"] as? String == "main")
}

@Test func githubInlineCommentsUseCurrentHeadAndOnlyReviewedDiffLines() async throws {
    let item = threadReview(github: true), patch = "@@ -1 +1 @@\n-old\n+new\n"
    let transport = try ThreadTransport([item, item, [["filename": "file.txt", "status": "modified", "patch": patch]], [:]])
    let client = try threadClient(transport), review = try await client.detail(2)
    let file = HostedReviewFile(path: "file.txt", previousPath: nil, status: "modified", patch: patch)
    try await client.commentInline(review, file: file, line: 1, side: .right, text: "Reviewed line")
    let request = try #require(await transport.requests.last), body = try threadBody(request)
    #expect(request.url?.path == "/repos/upstream/fixture/pulls/2/comments")
    #expect(body["commit_id"] as? String == "abc123" && body["line"] as? Int == 1 && body["side"] as? String == "RIGHT")
    let stale = try ThreadTransport([item, threadReview(github: true, head: "changed")]), staleClient = try threadClient(stale)
    let oldReview = try await staleClient.detail(2)
    await #expect(throws: GitFailure.self) { try await staleClient.commentInline(oldReview, file: file, line: 1, side: .right, text: "Stale") }
    #expect(await stale.requests.allSatisfy { $0.httpMethod == "GET" })
}

@Test func gitlabInlinePositionsBindBaseStartHeadAndBothContextCoordinates() async throws {
    let item = threadReview(github: false), patch = "@@ -1 +1 @@\n context\n"
    let transport = try ThreadTransport([item, item, [["new_path": "new.txt", "old_path": "old.txt", "diff": patch]], [:]])
    let client = try threadClient(transport, github: false), review = try await client.detail(2)
    try await client.commentInline(review, file: HostedReviewFile(path: "new.txt", previousPath: "old.txt", status: "changed", patch: patch), line: 1, side: .right, text: "Context")
    let request = try #require(await transport.requests.last), body = try threadBody(request), position = try #require(body["position"] as? [String: Any])
    #expect(position["base_sha"] as? String == "base123" && position["start_sha"] as? String == "start123" && position["head_sha"] as? String == "abc123")
    #expect(position["old_line"] as? Int == 1 && position["new_line"] as? Int == 1)
    #expect(position["old_path"] as? String == "old.txt" && position["new_path"] as? String == "new.txt")
}

@Test func threadPaginationRetainsReplyGroupingAndExposesMoreServerPages() async throws {
    var comments: [[String: Any]] = [["id": 10, "path": "file.txt", "line": 1, "side": "RIGHT", "body": "Root", "user": ["login": "author"]]]
    for id in 11...109 { comments.append(["id": id, "in_reply_to_id": 10, "path": "file.txt", "body": "Reply", "user": ["login": "author"]]) }
    let transport = try ThreadTransport([threadReview(github: true), comments, [:]]), client = try threadClient(transport)
    let review = try await client.detail(2), page = try await client.threadPage(review)
    #expect(page.items.count == 1 && page.items[0].comments.count == 100 && page.hasMore)
    try await client.reply(review, thread: page.items[0], text: "Thread reply")
    #expect(await transport.requests.last?.url?.path == "/repos/upstream/fixture/pulls/2/comments/10/replies")
}
