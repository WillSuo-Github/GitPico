import Foundation

/// Public Sparkle feeds use GitHub's download URLs, avoiding anonymous REST quotas.
public struct GitHubPublicRelease: Sendable {
    public let project: String
    public init(project: String) throws {
        let parts = project.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }) else { throw GitFailure("Choose a valid GitHub owner/repository for updates.") }
        self.project = project
    }
    public var feedURL: URL { URL(string: "https://github.com/" + project + "/releases/latest/download/appcast.xml")! }
    public func archiveURL(build: String) throws -> URL {
        guard build.count == 14, build.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw GitFailure("The update has an invalid date build number.") }
        return URL(string: "https://github.com/" + project + "/releases/download/build-" + build + "/GitPico-" + build + ".zip")!
    }
    public func permits(_ url: URL, build: String) -> Bool {
        guard let expected = try? archiveURL(build: build) else { return false }
        return url == expected
    }
    public func configureDownload(_ request: NSMutableURLRequest, build: String) throws {
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.httpShouldHandleCookies = false
        guard let url = request.url, permits(url, build: build) else { throw GitFailure("The update archive is not the expected public GitHub release download.") }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    }
}
