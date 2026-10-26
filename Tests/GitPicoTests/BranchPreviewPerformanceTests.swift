import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@MainActor struct PreviewFixture {
    let root: URL
    let repository: GitRepository
    let store: RepositoryStore
    let tips: [String]
    static func make(commits: Int = 24, branches: Int = 8, untracked: Int = 0, reader: any HistoryReading = GitHistoryReader()) async throws -> PreviewFixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GitPico-preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = try await GitRepository.create(at: root.appendingPathComponent("Repo"))
        let url = await repo.root
        for (key,value) in [("user.name","Preview Test"),("user.email","preview@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await GitProcess.run(["config",key,value], at: url) }
        var stream = Data()
        for index in 1...commits {
            let message = "Preview commit \(index)\n"
            stream += Data(("commit refs/heads/main\nmark :\(index)\ncommitter Preview Test <preview@example.invalid> \(1_700_000_000 + index) +0000\ndata \(message.utf8.count)\n" + message + (index > 1 ? "from :\(index - 1)\n" : "") + "\n").utf8)
        }
        _ = try await GitProcess.run(["fast-import", "--quiet"], at: url, input: stream)
        _ = try await GitProcess.run(["reset", "--hard", "main"], at: url)
        let hashes = try await GitProcess.run(["rev-list", "main"], at: url).text.split(separator: "\n").map(String.init)
        let tips = (0..<branches).map { hashes[min($0 * 2, hashes.count - 1)] }
        let refs = tips.enumerated().map { "create refs/heads/preview/branch-\($0.offset) \($0.element)\n" }.joined()
        _ = try await GitProcess.run(["update-ref", "--stdin"], at: url, input: Data(refs.utf8))
        for index in 0..<untracked { try Data("untracked".utf8).write(to: url.appendingPathComponent("local-\(index)")) }
        let store = RepositoryStore(library: RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: []), historyReader: reader)
        store.toolPreferences = ExternalToolPreferences(file: root.appendingPathComponent("tools.json"))
        await store.open(url)
        return PreviewFixture(root: root, repository: repo, store: store, tips: tips)
    }
    func clean() { store.cancelPreviewWork(); try? FileManager.default.removeItem(at: root) }
    func waitForBranch(_ index: Int) async throws {
        let deadline = Date().addingTimeInterval(30)
        while (store.isBusy || store.selectedCommit?.hash != tips[index]) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.selectedCommit?.hash == tips[index])
        #expect(!store.isBusy)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RUN_PREVIEW_BENCHMARK"] == "1", "Explicit isolated performance run only."))
@MainActor func branchPreviewPerformanceBenchmark() async throws {
    let f = try await PreviewFixture.make(commits: 600, branches: 120, untracked: 2000); defer { f.clean() }
    let before = try await f.repository.headPosition()
    var samples: [[String:Any]] = []
    for index in [5,70,105,5,70,105] {
        let start = ContinuousClock.now
        f.store.navigate(.reference("refs/heads/preview/branch-\(index)"))
        try await f.waitForBranch(index)
        let duration = start.duration(to: .now)
        samples.append(["branch":index,"seconds":Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18])
    }
    #expect(try await f.repository.headPosition() == before)
    if let output = ProcessInfo.processInfo.environment["GITPICO_PREVIEW_BENCHMARK_REPORT"] {
        let value: [String:Any] = ["commits":600,"branches":120,"untrackedFiles":2000,"samples":samples,"headUnchanged":true]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RUN_PREVIEW_RENDER_BENCHMARK"] == "1", "Explicit suppressed history rendering benchmark only."))
@MainActor func branchPreviewRenderPerformanceBenchmark() async throws {
    let f = try await PreviewFixture.make(commits: 3000, branches: 120); defer { f.clean() }
    let changedFiles = Int(ProcessInfo.processInfo.environment["GITPICO_PREVIEW_RENDER_CHANGED_FILES"] ?? "0") ?? 0
    if changedFiles > 0 {
        var stream = "blob\nmark :1\ndata 8\npreview\n\n"
        for index in [5,70,105] {
            let message = "Large preview \(index)\n"
            stream += "commit refs/heads/preview/branch-\(index)\ncommitter Preview Test <preview@example.invalid> \(1_700_010_000 + index) +0000\ndata \(message.utf8.count)\n" + message + "from \(f.tips[index])\n"
            for file in 0..<changedFiles { stream += "M 100644 :1 preview-\(file).txt\n" }
            stream += "\n"
        }
        _ = try await GitProcess.run(["fast-import", "--quiet"], at: f.repository.root, input: Data(stream.utf8))
        f.store.snapshot = try await f.repository.snapshot(countHistory: false)
    }
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.setFrame(NSRect(x: -10000, y: -10000, width: 1200, height: 850), display: false)
    window.contentView = NSHostingView(rootView: HistoryView(store: f.store))
    defer { window.contentView = nil; window.close() }
    var maximumGap = 0.0
    let heartbeat = Task { @MainActor in
        var previous = ContinuousClock.now
        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
            let now = ContinuousClock.now
            maximumGap = max(maximumGap, previous.duration(to: now).secondsValue)
            previous = now
        }
    }
    defer { heartbeat.cancel() }
    var samples: [[String: Any]] = []
    let rounds = Int(ProcessInfo.processInfo.environment["GITPICO_PREVIEW_RENDER_ROUNDS"] ?? "3") ?? 3
    for index in (0..<rounds).flatMap({ _ in [5,70,105] }) {
        maximumGap = 0
        let start = ContinuousClock.now
        f.store.navigate(.reference("refs/heads/preview/branch-\(index)"))
        let selectionSeconds = start.duration(to: .now).secondsValue
        await f.store.historyTask?.value
        let historySeconds = start.duration(to: .now).secondsValue
        await f.store.detailTask?.value
        let detailSeconds = start.duration(to: .now).secondsValue
        let layoutStart = ContinuousClock.now
        window.contentView?.layoutSubtreeIfNeeded()
        let layoutSeconds = layoutStart.duration(to: .now).secondsValue
        try await Task.sleep(for: .milliseconds(100))
        samples.append(["branch":index, "selectionSeconds":selectionSeconds, "historySeconds":historySeconds, "detailSeconds":detailSeconds, "layoutSeconds":layoutSeconds, "maximumMainActorGapSeconds":maximumGap])
        #expect(f.store.selectedCommit?.hash == f.store.previewedReference?.hash)
        if changedFiles > 0 { #expect(f.store.commitDetail?.files.count == changedFiles) }
    }
    #expect(!NSApp.isActive && !window.isVisible)
    if let output = ProcessInfo.processInfo.environment["GITPICO_PREVIEW_RENDER_BENCHMARK_REPORT"] {
        try JSONSerialization.data(withJSONObject: ["commits":3000,"branches":120,"changedFiles":changedFiles,"samples":samples], options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
    if let path = ProcessInfo.processInfo.environment["GITPICO_PREVIEW_RENDER_CAPTURE_DIRECTORY"] {
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(150))
            let view = try #require(window.contentView?.superview)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("history-\(dark ? "dark" : "light").png"))
        }
    }
}
