import Foundation
import Testing
@testable import GitCore

@Test func hostedRepositoryLinksUseTheWebsiteWithoutAPIAuthentication() throws {
    let github = try HostedRepository(remote: "git@github.com:example/project.git", provider: .github)
    #expect(github.reviewsWebURL.absoluteString == "https://github.com/example/project/pulls")
    let gitlab = try HostedRepository(remote: "ssh://git@git.example.invalid:2222/team/sub/project.git", provider: .gitlab)
    #expect(gitlab.reviewsWebURL.absoluteString == "https://git.example.invalid/team/sub/project/-/merge_requests")
    let enterprise = try HostedRepository(remote: "https://git.example.invalid:8443/team/project.git", provider: .github)
    #expect(enterprise.reviewsWebURL.absoluteString == "https://git.example.invalid:8443/team/project/pulls")
    #expect(throws: GitFailure.self) { try HostedRepository(remote: "https://user:secret@github.com/example/project.git", provider: .github) }
    #expect(throws: GitFailure.self) { try HostedRepository(remote: "file:///tmp/project.git", provider: .github) }
}

@Test func legacyOAuthConfigurationDecodesWithoutRequestingMRAPIAccess() throws {
    let data = Data(#"{"provider":"gitlab","host":"gitlab.com","clientID":"fixture-client","apiAccess":true}"#.utf8)
    let configuration = try JSONDecoder().decode(OAuthConfiguration.self, from: data)
    #expect(configuration.scopes == ["read_user", "write_repository"])
    let url = try OAuthPKCE(state: "fixture", verifier: "fixture").authorizationURL(configuration)
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "scope" })?.value == "read_user write_repository")
}
