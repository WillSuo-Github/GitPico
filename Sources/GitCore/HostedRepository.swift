import Foundation

public struct HostedRepository: Sendable, Equatable {
    public let provider: OAuthProvider
    public let host: String
    public let project: String
    public init(remote: String, provider: OAuthProvider) throws {
        let host: String, path: String
        if let url = URLComponents(string: remote), ["https", "ssh"].contains(url.scheme), let hostname = url.host {
            guard url.password == nil else { throw GitFailure("Remove embedded passwords from the remote URL before opening the hosting website.") }
            host = hostname.lowercased() + (url.scheme == "https" ? url.port.map { ":\($0)" } ?? "" : "")
            path = url.path
        } else if let colon = remote.firstIndex(of: ":"), !remote.contains("://") {
            host = String(remote[..<colon].split(separator: "@").last ?? "").lowercased()
            path = String(remote[remote.index(after: colon)...])
        } else { throw GitFailure("Select a GitHub or GitLab HTTPS/SSH remote.") }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let project = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed
        let parts = project.split(separator: "/", omittingEmptySubsequences: false)
        guard let address = URLComponents(string: "https://" + host), address.host?.isEmpty == false,
              address.user == nil, address.password == nil, address.path.isEmpty, address.query == nil, address.fragment == nil,
              !host.contains(where: { $0.isWhitespace || $0 == "\\" || $0 == "\0" }),
              parts.count >= 2, provider != .github || parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(where: { $0.isWhitespace || $0 == "\\" || $0 == "\0" }) }) else { throw GitFailure("The remote does not identify a supported hosted project.") }
        self.provider = provider; self.host = host; self.project = project
    }
    public var webURL: URL { URL(string: "https://" + host + "/" + project.split(separator: "/").map { Self.component(String($0)) }.joined(separator: "/"))! }
    public var reviewsWebURL: URL {
        webURL.appendingPathComponent(provider == .github ? "pulls" : "-/merge_requests")
    }
    static func component(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))! }
}
