import AppKit
import Foundation
import SwiftUI
import Testing
@testable import GitCore
@testable import GitPico

@Test func cloneTransferMetricsParsesCountsSizeRateAndFiltering() {
    let output = """
    Cloning into '/tmp/GitPico'...
    remote: Enumerating objects: 4521, done.
    remote: Counting objects:  45% (120/265)
    Receiving objects:  64% (2894/4521), 18.42 MiB | 6.15 MiB/s
    warning: release/99% is not a progress line
    """
    let metrics = RepositoryCloneSession.TransferMetrics.latest(in: output)
    #expect(metrics == RepositoryCloneSession.TransferMetrics(
        stage: "Receiving objects",
        percent: 64,
        counts: "2894/4521",
        transferred: "18.42 MiB",
        rate: "6.15 MiB/s"
    ))
    #expect(metrics?.detailSummary?.contains("18.42 MiB") == true)
    #expect(metrics?.detailSummary?.contains("6.15 MiB/s") == true)

    let lfsOutput = "Filtering content:  33% (4/12), 14.20 MiB | 3.10 MiB/s, done.\n"
    let lfs = RepositoryCloneSession.TransferMetrics.latest(in: lfsOutput)
    #expect(lfs?.stage == "Filtering content")
    #expect(lfs?.percent == 33)
    #expect(lfs?.transferred == "14.20 MiB")
    #expect(lfs?.rate == "3.10 MiB/s")
}

@Test func cloneSessionSanitizesEmbeddedCredentialsAndTracksMonotonicSteps() {
    let sanitized = RepositoryCloneSession.sanitizedDisplaySource("https://alice:ghp_superSecretToken@github.com/acme/widgets.git?ref=main#top")
    #expect(sanitized == "github.com/acme/widgets")
    #expect(!sanitized.contains("ghp_superSecretToken"))
    #expect(!sanitized.contains("alice"))

    #expect(RepositoryCloneSession.sanitizedDisplaySource("git@github.com:acme/widgets.git") == "github.com/acme/widgets")

    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Widgets", isDirectory: true)
    var session = RepositoryCloneSession(destination: destination, source: "https://github.com/acme/widgets.git", recursive: true, lfs: .download)
    let cancellation = GitNetworkCancellation()
    let recordID = UUID()

    session.apply(GitNetworkEvent(
        id: recordID, command: "clone", repository: "Widgets", started: Date(), phase: .running,
        output: "remote: Enumerating objects: 420, done.\nReceiving objects:  50% (210/420), 4.20 MiB | 2.10 MiB/s",
        cancellation: cancellation
    ))
    #expect(session.reachedStep == .download)
    #expect(session.headline == "Receiving objects")
    #expect(session.transferProgress?.percent == 50)

    session.apply(GitNetworkEvent(
        id: recordID, command: "clone", repository: "Widgets", started: Date(), phase: .running,
        output: "Resolving deltas: 100% (120/120), done.\nSubmodule 'vendor/core' (https://example.com/core.git) registered for path 'vendor/core'\nReceiving objects:  20% (10/50), 120 KiB | 60 KiB/s",
        cancellation: cancellation
    ))
    #expect(session.reachedStep == .checkout)
    #expect(session.activeSubmodule == "vendor/core")

    session.phase = .failed("fatal: authentication failed")
    session.apply(GitNetworkEvent(
        id: recordID, command: "clone", repository: "Widgets", started: Date(), phase: .running,
        output: "Receiving objects:  99% (49/50)",
        cancellation: cancellation
    ))
    #expect(session.phase == .failed("fatal: authentication failed"))
    #expect(session.isAuthenticationFailure)
}

@Test @MainActor func pickerCloneLifecycleHandlesSuccessFailureAndCancelInline() async throws {
    let base = try await WorkingAppFixture.make(); defer { base.clean() }
    let sourceRoot = await base.repository.root
    let bareRemote = base.root.appendingPathComponent("Remote.git", isDirectory: true)
    _ = try await GitProcess.run(["clone", "--bare", sourceRoot.path, bareRemote.path], at: base.root)
    let workspace = RepositoryWorkspace(library: base.store.library)
    defer { workspace.shutdown() }
    let tab = workspace.activeTab
    let store = tab.store

    let missingDestination = base.root.appendingPathComponent("MissingClone", isDirectory: true)
    store.createRepository(
        at: missingDestination,
        source: base.root.appendingPathComponent("DoesNotExist.git").path,
        recursive: true,
        allowLocalTransport: true,
        lfs: .pointersOnly
    )
    #expect(store.cloneSession?.name == "MissingClone")
    #expect(store.cloneSession?.phase == RepositoryCloneSession.Phase.cloning)
    await store.cloneTask?.value
    #expect(!store.isBusy)
    #expect(store.error == nil)
    #expect(store.cloneSession?.failureMessage != nil)
    #expect(store.cloneSession?.finished != nil)

    store.editCloneSession()
    let request = try #require(store.creationRequest)
    #expect(request.clone && request.name == "MissingClone" && request.recursive && request.enableLFS && !request.downloadLFS && request.allowLocalTransport)
    #expect(request.parent == missingDestination.deletingLastPathComponent())
    store.creationRequest = nil

    store.dismissCloneSession()
    #expect(store.cloneSession == nil)

    let successDestination = base.root.appendingPathComponent("ClonedOK", isDirectory: true)
    store.createRepository(at: successDestination, source: bareRemote.path, allowLocalTransport: true)
    #expect(store.cloneSession?.name == "ClonedOK")
    await store.cloneTask?.value
    #expect(!store.isBusy)
    #expect(store.cloneSession == nil)
    #expect(!tab.showsRepositoryPicker)
    #expect(store.snapshot?.root.resolvingSymlinksInPath().standardizedFileURL == successDestination.resolvingSymlinksInPath().standardizedFileURL)

    workspace.showRepositories(from: store)
    let cancelledDestination = base.root.appendingPathComponent("CancelledClone", isDirectory: true)
    let session = RepositoryCloneSession(destination: cancelledDestination, source: "https://github.com/acme/demo.git")
    let cancellation = GitNetworkCancellation()
    let recordID = UUID()
    store.cloneSession = session
    store.handleCloneNetworkEvent(
        GitNetworkEvent(
            id: recordID,
            command: "clone",
            repository: "CancelledClone",
            started: Date(),
            phase: .running,
            output: "Receiving objects:  40% (40/100), 2.00 MiB | 1.00 MiB/s",
            cancellation: cancellation
        ),
        sessionID: session.id
    )
    #expect(store.cloneSession?.canCancel == true)
    store.cancelActiveClone()
    #expect(cancellation.isCancelled)
    #expect(store.cloneSession?.isCancelling == true)
    store.handleCloneNetworkEvent(
        GitNetworkEvent(
            id: recordID,
            command: "clone",
            repository: "CancelledClone",
            started: Date(),
            phase: .cancelled,
            output: "Network operation cancelled.",
            cancellation: cancellation
        ),
        sessionID: session.id
    )
    #expect(store.cloneSession?.phase == RepositoryCloneSession.Phase.cancelled)
    #expect(store.cloneSession?.isCancelling == false)
    store.dismissCloneSession()
    #expect(store.cloneSession == nil)
}

@Test @MainActor func captureCloneProgressVisualStatesOffscreen() async throws {
    guard let directory = ProcessInfo.processInfo.environment["GITPICO_CLONE_UI_CAPTURE_DIR"], !directory.isEmpty else { return }
    let outputDir = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

    let libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-clone-capture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: libraryRoot) }

    let library = RepositoryLibrary(file: libraryRoot.appendingPathComponent("library.json"))
    let workspace = RepositoryWorkspace(library: library)
    defer { workspace.shutdown() }
    let tab = workspace.activeTab
    let store = tab.store

    func render<V: View>(_ view: V, size: CGSize?, appearance: NSAppearance.Name, filename: String) async throws {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let styled = view
            .environment(\.repositoryStatusMotionEnabled, false)
            .environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor))
        let host: NSHostingView<AnyView>
        if let size {
            host = NSHostingView(rootView: AnyView(styled.frame(width: size.width, height: size.height)))
        } else {
            host = NSHostingView(rootView: AnyView(styled))
        }
        let resolvedSize = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: resolvedSize)
        let panel = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: resolvedSize.width, height: resolvedSize.height), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: appearance)
        panel.backgroundColor = .windowBackgroundColor
        panel.contentView = host
        defer { panel.contentView = nil; panel.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        try #require(image.representation(using: .png, properties: [:])).write(to: outputDir.appendingPathComponent(filename))
    }

    let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/GitPico-Demo", isDirectory: true)
    var running = RepositoryCloneSession(
        destination: destination,
        source: "https://github.com/willsuo/GitPico-Demo.git",
        recursive: true,
        lfs: .download,
        started: Date().addingTimeInterval(-18)
    )
    running.reachedStep = .download
    running.output = """
    Cloning into '/Users/willsuo/Projects/GitPico-Demo'...
    remote: Enumerating objects: 4521, done.
    remote: Counting objects: 100% (265/265), done.
    remote: Compressing objects: 100% (142/142), done.
    Receiving objects:  64% (2894/4521), 18.42 MiB | 6.15 MiB/s
    """
    store.isBusy = true
    store.activity = String(localized: "Cloning repository…")
    store.cloneSession = running

    try await render(RepositoryWorkspaceView(workspace: workspace, tab: tab, presentsAlerts: false), size: CGSize(width: 1200, height: 760), appearance: .aqua, filename: "clone-running-light.png")
    try await render(RepositoryWorkspaceView(workspace: workspace, tab: tab, presentsAlerts: false), size: CGSize(width: 1200, height: 760), appearance: .darkAqua, filename: "clone-running-dark.png")

    var failed = running
    failed.phase = .failed("fatal: Authentication failed for 'https://github.com/willsuo/GitPico-Demo.git/'")
    failed.finished = Date()
    failed.output += "\nfatal: Authentication failed for '[redacted]'"
    store.isBusy = false
    store.activity = ""
    store.cloneSession = failed

    try await render(RepositoryWorkspaceView(workspace: workspace, tab: tab, presentsAlerts: false), size: CGSize(width: 1200, height: 760), appearance: .aqua, filename: "clone-failed-light.png")

    store.cloneSession = nil
    let sheetRequest = RepositoryCreationRequest(
        clone: true,
        source: "https://github.com/willsuo/GitPico-Demo.git",
        name: "GitPico-Demo",
        parent: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects", isDirectory: true),
        recursive: true,
        enableLFS: true
    )
    try await render(RepositoryCreationSheet(store: store, request: sheetRequest), size: nil, appearance: .aqua, filename: "clone-sheet-light.png")

    #expect(NSApp?.isActive != true && (NSApp?.windows.filter(\.isVisible).isEmpty ?? true))
}
