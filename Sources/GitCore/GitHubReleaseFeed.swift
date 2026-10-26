import Foundation

public struct GitHubReleaseFeed: Sendable {
    public let feedURL: URL
    public let assets: Set<URL>
    public let releaseURL: URL
    public let tag: String
    public func permits(_ url: URL) -> Bool { assets.contains(url) && url.scheme == "https" && url.host == "api.github.com" && url.user == nil && url.password == nil }
}
public struct GitHubReleaseFeedClient: Sendable {
    private let transport: any OAuthHTTPTransport
    public init(transport: any OAuthHTTPTransport = OAuthHTTPSClient(maximumResponseBytes: 1024 * 1024)) { self.transport = transport }
    public func latest(project: String, credential: GitStoredCredential) async throws -> GitHubReleaseFeed {
        let parts = project.split(separator: "/", omittingEmptySubsequences: false)
        guard credential.host == "github.com", parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) }) else { throw GitFailure("Choose a github.com account and a valid owner/repository for updates.") }
        let base = "https://api.github.com/repos/" + project
        var request = URLRequest(url: URL(string: base + "/releases/latest")!)
        request.setValue("Bearer " + credential.secret, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GitPico", forHTTPHeaderField: "User-Agent")
        let response = try await transport.send(request)
        guard response.status == 200 else {
            throw GitFailure(response.status == 404 ? "No published update release is available, or this account cannot read the private repository." : "GitHub update lookup failed (HTTP \(response.status)). Check the selected account and network.")
        }
        guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              object["draft"] as? Bool == false, object["prerelease"] as? Bool == false,
              let tag = object["tag_name"] as? String,
              let values = object["assets"] as? [[String: Any]] else { throw GitFailure("GitHub returned an invalid update release.") }
        var assets: Set<URL> = [], feed: URL?
        for asset in values {
            guard let id = asset["id"] as? Int, id > 0, let name = asset["name"] as? String else { continue }
            let url = URL(string: base + "/releases/assets/\(id)")!
            if name.hasSuffix(".zip") { assets.insert(url) }
            if name == "appcast.xml" { feed = url }
        }
        guard let feed, !assets.isEmpty else { throw GitFailure("The latest release is missing appcast.xml or its signed installation archive.") }
        return GitHubReleaseFeed(feedURL: feed, assets: assets, releaseURL: URL(string: "https://github.com/" + project + "/releases")!, tag: tag)
    }
}
