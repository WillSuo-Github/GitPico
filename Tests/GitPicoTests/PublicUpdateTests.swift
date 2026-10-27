import AppKit
import Foundation
import GitCore
import Testing
@testable import GitPico

private final class PublicUpdateRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let url = request.url
        let allowed = url?.scheme == "https" && url?.user == nil && url?.password == nil && ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url?.host)
        completionHandler(allowed ? request : nil)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_VERIFY_PUBLIC_UPDATES"] == "1", "Explicit anonymous public feed download only."))
@MainActor func publicUpdatesResolveWithoutAnyAccountOrWindow() async throws {
    let source = try GitHubPublicRelease(project: "WillSuo-Github/GitPico")
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.timeoutIntervalForRequest = 30
    let session = URLSession(configuration: config, delegate: PublicUpdateRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: source.feedURL)
    request.setValue("GitPico", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(data.count < 1024 * 1024 && String(decoding: data, as: UTF8.self).contains("<rss"))
    if let path = ProcessInfo.processInfo.environment["GITPICO_UPDATE_DIAGNOSTIC_OUTPUT"] {
        let report: [String: Any] = ["succeeded": true, "anonymous": true, "usesRESTAPI": false, "feedBytes": data.count]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
