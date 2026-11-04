import AppKit
import SwiftUI
import Testing
@testable import GitPico

@Test func failureSummaryFindsDiagnosticsAfterCarriageReturnProgress() {
    let progress = (1...90).map { "Counting objects: \($0)% (\($0)/90)\r" }.joined()
    let failure = GitOperationFailure("Enumerating objects: 90, done.\n" + progress + "\nerror: RPC failed; curl 56 transport interrupted\nfatal: the remote end hung up unexpectedly\nEverything up-to-date\n")
    #expect(failure.summary == "error: RPC failed; curl 56 transport interrupted\nfatal: the remote end hung up unexpectedly")
    #expect(failure.details.contains("Counting objects:") && failure.details.contains("Everything up-to-date"))
    #expect(!failure.summary.contains("Counting objects:"))
}

@Test func failureSummaryBoundsUnstructuredOutputAndKeepsUnicodeAndRedaction() {
    let output = String(repeating: "warning: earlier diagnostic\n", count: 4000)
        + "fatal: " + String(repeating: "失败", count: 3000)
        + "\nerror: permission denied for https://user:private@fixture.invalid/repo ghp_fixturetoken"
    let failure = GitOperationFailure(output)
    #expect(failure.summary.count <= 420 && failure.omittedEarlierOutput)
    #expect(failure.details.count <= 32_768)
    for value in ["user:private", "fixture.invalid", "ghp_fixturetoken"] {
        #expect(!failure.summary.contains(value) && !failure.details.contains(value))
    }
    #expect(failure.summary.contains("permission denied") && failure.summary.contains("失败"))
    #expect(!failure.summary.contains("�"))
}

@Test func failureSummaryPreservesActionableNonGitErrorsAndProgressOnlyFallback() {
    #expect(GitOperationFailure("A signing key is required.\nChoose a key in Settings.").summary == "A signing key is required.\nChoose a key in Settings.")
    for output in ["", "remote: Counting objects: 64% (58/90)\rEnumerating objects: 90, done.\n"] {
        let failure = GitOperationFailure(output)
        #expect(!failure.summary.isEmpty && !failure.summary.contains("Counting objects:") && !failure.summary.contains("Enumerating objects:"))
    }
    let rejected = GitOperationFailure("To /tmp/fixture\n ! [rejected] main -> main (non-fast-forward)\nerror: failed to push some refs\nhint: Fetch and review before retrying.")
    #expect(rejected.summary.contains("non-fast-forward") && rejected.details.contains("Fetch and review"))
}

@Test @MainActor func verboseFailureDetailsRemainBoundedWithoutPresentingAWindow() async throws {
    let failure = GitOperationFailure(String(repeating: "Counting objects: 64% (58/90)\r", count: 5000) + "\nfatal: fixture connection interrupted")
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    defer { window.contentView = nil; window.close() }
    window.setContentSize(NSSize(width: 640, height: 460))
    window.contentView = NSHostingView(rootView: GitOperationFailureDetails(failure: failure))
    try await Task.sleep(for: .milliseconds(250))
    let view = try #require(window.contentView)
    view.layoutSubtreeIfNeeded()
    // This native window includes its title bar in the hosting view's safe area.
    #expect(view.fittingSize.width == 640 && (460...500).contains(view.fittingSize.height))
    #expect((460...500).contains(view.bounds.height))
    func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    let scroll = try #require(descendants(view).compactMap { $0 as? NSScrollView }.first)
    #expect(scroll.frame.height > 100 && scroll.frame.height < 360)
    #expect(try #require(scroll.documentView).bounds.height > scroll.contentView.bounds.height)
    if let output = ProcessInfo.processInfo.environment["GITPICO_FAILURE_CAPTURE_OUTPUT"] {
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(150))
            let capture = view.superview ?? view
            capture.layoutSubtreeIfNeeded()
            let bitmap = try #require(capture.bitmapImageRepForCachingDisplay(in: capture.bounds))
            capture.cacheDisplay(in: capture.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(dark ? "failure-dark.png" : "failure-light.png"))
        }
    }
    #expect(!window.isVisible && !NSApp.isActive)
}
