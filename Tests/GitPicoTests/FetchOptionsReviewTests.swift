import AppKit
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test func largeFetchDisconnectIsNotMisclassifiedAsAuthentication() {
    let log = """
    Receiving objects: 7% (60/794), 104.50 MiB | 403.00 KiB/s
    fetch-pack: unexpected disconnect while reading sideband packet
    """
    #expect(networkTransferWasInterrupted(log))
    #expect(networkFailureAdvice(log) != networkFailureAdvice("fatal: Authentication failed"))
    #expect(networkFailureAdvice(log, timedOut: true) != networkFailureAdvice(log))
    #expect(networkFailureAdvice("Receiving objects: 10% (403/4030)") != networkFailureAdvice("fatal: Authentication failed"))
}

@Test @MainActor func fetchReviewOpensOptionsWithoutStartingTransfer() async throws {
    let fixture = try await WorkingAppFixture.make(); defer { fixture.clean() }
    let root = await fixture.repository.root
    // The destination is disposable; this test never contacts a remote server.
    _ = try await GitProcess.run(["remote", "add", "origin", fixture.root.appendingPathComponent("remote.git").path], at: root)
    await fixture.store.openInPlace(root)
    let store = fixture.store
    store.reviewFetch(mode: .largeTransfer)
    await store.metadataTask?.value
    let request = try #require(store.managementRequest)
    guard case .fetch(nil, mode: .largeTransfer) = request.action else {
        Issue.record("Expected the large-transfer fetch options.")
        return
    }
    #expect(!store.isBusy && store.operationFeedback == nil)
    #expect(store.networkActivity?.records.isEmpty == true)

    if let capture = ProcessInfo.processInfo.environment["GITPICO_FETCH_OPTIONS_CAPTURE"] {
        let host = NSHostingView(rootView: ManagementSheet(store: store, request: request).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 520, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let height = ceil(host.fittingSize.height)
        window.setContentSize(NSSize(width: 520, height: height))
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        try #require(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: capture))
        #expect(!window.isVisible && !NSApp.isActive)
    }
}
