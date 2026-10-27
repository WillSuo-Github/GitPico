import Foundation
import Testing
@testable import GitCore

@Test func publicUpdatesUseDirectDownloadURLsWithoutRESTOrCredentials() throws {
    let source = try GitHubPublicRelease(project: "example/public")
    #expect(source.feedURL.absoluteString == "https://github.com/example/public/releases/latest/download/appcast.xml")
    let archive = try source.archiveURL(build: "20261027170000")
    #expect(archive.absoluteString == "https://github.com/example/public/releases/download/build-20261027170000/GitPico-20261027170000.zip")
    let request = NSMutableURLRequest(url: archive)
    request.setValue("Bearer stale-account", forHTTPHeaderField: "Authorization")
    request.setValue("stale-cookie", forHTTPHeaderField: "Cookie")
    try source.configureDownload(request, build: "20261027170000")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(!request.httpShouldHandleCookies)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
}

@Test func publicUpdatesRejectForeignDownloadsAndInvalidVersions() throws {
    let source = try GitHubPublicRelease(project: "example/public")
    let good = try source.archiveURL(build: "20261027170000")
    for project in ["../public", "example/../public", "https://github.com/example/public", "example/public?token=fixture", "example/公開"] {
        #expect(throws: GitFailure.self) { try GitHubPublicRelease(project: project) }
    }
    for build in ["0.01", "20261027", "20261027170000/other", "２０２６１０２７１７００００"] {
        #expect(throws: GitFailure.self) { try source.archiveURL(build: build) }
    }
    for value in [good.absoluteString.replacingOccurrences(of: "example/public", with: "example/other"),
                  good.absoluteString.replacingOccurrences(of: "https:", with: "http:"),
                  good.absoluteString.replacingOccurrences(of: "github.com/", with: "user@github.com/"),
                  good.absoluteString + "?token=fixture", "https://api.github.com/repos/example/public/releases/assets/11"] {
        let request = NSMutableURLRequest(url: try #require(URL(string: value)))
        request.setValue("Bearer stale-account", forHTTPHeaderField: "Authorization")
        #expect(throws: GitFailure.self) { try source.configureDownload(request, build: "20261027170000") }
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
    #expect(!source.permits(good, build: "20261027170001"))
}
