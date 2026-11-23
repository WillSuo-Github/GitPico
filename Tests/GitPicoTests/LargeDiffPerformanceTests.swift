import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

private func makeSyntheticLargeSwiftDiff(lineCount: Int) -> String {
    var output = "diff --git a/Sources/GeneratedBig.swift b/Sources/GeneratedBig.swift\n"
    output += "index 1111111..2222222 100644\n"
    output += "--- a/Sources/GeneratedBig.swift\n"
    output += "+++ b/Sources/GeneratedBig.swift\n"
    output += "@@ -1,\(lineCount) +1,\(lineCount) @@\n"
    output.reserveCapacity(lineCount * 110)
    for index in 0..<lineCount {
        if index % 4 == 0 {
            output += "-let oldValue_\(index) = \"sample string \(index)\" // comment \(index)\n"
            output += "+let newValue_\(index) = \"updated string \(index)\" // changed \(index)\n"
        } else {
            output += " func computeItem_\(index)(_ input: Int) -> Int { return input + \(index) }\n"
        }
    }
    return output
}

private func makeSyntheticMinifiedDiff(lineLength: Int) -> String {
    let chunk = "const item={id:123,name:\"alpha\",flag:true,value:456};"
    let repeats = max(1, lineLength / chunk.count)
    let oldLine = String(repeating: chunk, count: repeats) + "oldTail"
    let newLine = String(repeating: chunk, count: repeats) + "newTail"
    return """
    diff --git a/dist/bundle.min.js b/dist/bundle.min.js
    index 1111111..2222222 100644
    --- a/dist/bundle.min.js
    +++ b/dist/bundle.min.js
    @@ -1,2 +1,2 @@
    -\(oldLine)
    +\(newLine)
     /* end */
    """
}

@Test @MainActor func largeAndMinifiedDiffViewsLayoutAndDrawWithoutFreezingOrCrashing() async throws {
    let originalSplit = AppPreferences.shared.splitDiff
    defer { AppPreferences.shared.splitDiff = originalSplit }

    let largeDiff = makeSyntheticLargeSwiftDiff(lineCount: 12_000)
    let preparedPatch = PreparedPatch.make(largeDiff, path: "Sources/GeneratedBig.swift")
    let preparedDiff = PreparedDiff.make(largeDiff, path: "Sources/GeneratedBig.swift")
    let minifiedPrepared = PreparedPatch.make(makeSyntheticMinifiedDiff(lineLength: 120_000), path: "dist/bundle.min.js")

    #expect(preparedPatch.isTruncated)
    #expect(!preparedPatch.isBinary)
    #expect(preparedPatch.unifiedItems.count > 7_900)
    #expect(preparedPatch.splitItems.count > 5_000)
    #expect(preparedPatch.matchingLineIDs(query: "newValue_400 =").count == 1)
    #expect(preparedDiff.splitScrollTargets["line:10"] != nil)
    #expect(DiffCodeText.displayedColumnWidth(of: String(repeating: "x", count: 50_000)) == DiffCodeText.maxDisplayedUTF16Units + 26)
    #expect(DiffCodeText.displayedColumnWidth(of: "中文测试") == 8)

    let scrollState = SplitHorizontalScrollState()
    scrollState.syncLimits(left: 400, right: 200)
    #expect(scrollState.scrollBy(deltaX: -120, isRight: false))
    #expect(scrollState.leftOffset == 120 && scrollState.rightOffset == 0)
    #expect(!scrollState.scrollBy(deltaX: 500, isRight: true))
    #expect(scrollState.scrollBy(deltaX: -300, isRight: true))
    #expect(scrollState.rightOffset == 200)
    scrollState.reset()
    #expect(scrollState.leftOffset == 0 && scrollState.rightOffset == 0)

    func renderOffscreen<Content: View>(_ view: Content) -> Double {
        let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
        window.tabbingMode = .disallowed
        window.styleMask = [.borderless]
        window.contentMinSize = .zero
        window.appearance = NSAppearance(named: .aqua)
        defer { window.contentView = nil; window.close() }
        let start = ContinuousClock.now
        let host = NSHostingView(rootView: view.frame(width: 960, height: 640).environment(\.colorScheme, .light))
        window.contentView = host
        window.setFrame(NSRect(x: -10000, y: -10000, width: 960, height: 640), display: false)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    for split in [false, true] {
        AppPreferences.shared.splitDiff = split
        let chunkTime = renderOffscreen(ChunkDiffView(prepared: preparedPatch, chunkAction: { _ in }, lineAction: { _ in }))
        let diffTime = renderOffscreen(DiffView(text: largeDiff, title: "Sources/GeneratedBig.swift", initialPrepared: preparedDiff))
        let minifiedTime = renderOffscreen(ChunkDiffView(prepared: minifiedPrepared, chunkAction: { _ in }, lineAction: { _ in }))
        #expect(chunkTime < 2.0)
        #expect(diffTime < 2.0)
        #expect(minifiedTime < 2.0)
    }

    #expect(!NSApplication.shared.isActive && NSApplication.shared.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func workingCopyLoadsLargeRealRepositoryFileDiffSmoothly() async throws {
    let fixture = try await WorkingAppFixture.make()
    defer { fixture.clean() }
    let lines = (0..<15_000).map { "let item_\($0) = \"value_\($0)\" // line \($0)" }.joined(separator: "\n") + "\n"
    try await fixture.write("LargeGenerated.swift", lines)
    try await fixture.sync()
    let start = ContinuousClock.now
    fixture.store.setWorkingSelection(["LargeGenerated.swift"])
    await fixture.store.detailTask?.value
    let elapsed = start.duration(to: .now)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let prepared = try #require(fixture.store.workingPreparedDiff)
    #expect(fixture.store.diffError == nil)
    #expect(prepared.isTruncated)
    #expect(!prepared.isBinary)
    #expect(prepared.previews.first?.lines.count == 7_999)
    #expect(seconds < 5.0)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RUN_LARGE_DIFF_BENCHMARK"] == "1", "Explicit large diff benchmark only."))
@MainActor func largeDiffPerformanceBenchmark() async throws {
    func elapsedSeconds(_ start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    let hugeDiff = makeSyntheticLargeSwiftDiff(lineCount: 150_000)
    let hugeSizeMB = Double(hugeDiff.utf8.count) / (1024 * 1024)
    print(String(format: "[BENCH] hugeDiff size: %.2f MB", hugeSizeMB))

    var start = ContinuousClock.now
    let doc = DiffDocument(hugeDiff)
    print(String(format: "[BENCH] DiffDocument(150k lines, limit 8000): %.4fs (lines=%d, truncated=%@)", elapsedSeconds(start), doc.lines.count, "\(doc.isTruncated)"))

    start = .now
    let foundPath = CodeHighlighting.path(in: hugeDiff)
    print(String(format: "[BENCH] CodeHighlighting.path(150k lines): %.4fs (path=%@)", elapsedSeconds(start), foundPath))

    start = .now
    let patch = PatchDocument(hugeDiff)
    print(String(format: "[BENCH] PatchDocument(150k lines): %.4fs (hunks=%d, +%d/-%d)", elapsedSeconds(start), patch.hunks.count, patch.additions, patch.deletions))

    start = .now
    let previews = patch.preview()
    print(String(format: "[BENCH] PatchDocument.preview(limit 8000): %.4fs (previewLines=%d)", elapsedSeconds(start), previews.reduce(0) { $0 + $1.lines.count }))

    start = .now
    let highlighted = CodeHighlighting.prepare(previews[0].lines, path: "Sources/GeneratedBig.swift")
    print(String(format: "[BENCH] CodeHighlighting.prepare(8000 Swift lines): %.4fs (count=%d)", elapsedSeconds(start), highlighted.count))

    start = .now
    let prepared = PreparedPatch.make(hugeDiff, path: "Sources/GeneratedBig.swift")
    print(String(format: "[BENCH] PreparedPatch.make(150k lines): %.4fs", elapsedSeconds(start)))

    start = .now
    let isBinary = prepared.isBinary
    print(String(format: "[BENCH] prepared.isBinary (O(1) vs old 188ms scan): %.6fs (%@)", elapsedSeconds(start), "\(isBinary)"))

    let originalSplit = AppPreferences.shared.splitDiff
    defer { AppPreferences.shared.splitDiff = originalSplit }

    func measureHosting<Content: View>(label: String, view: Content) async throws {
        let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
        window.tabbingMode = .disallowed
        window.styleMask = [.borderless]
        window.contentMinSize = .zero
        window.appearance = NSAppearance(named: .aqua)
        defer { window.contentView = nil; window.close() }

        let start = ContinuousClock.now
        let host = NSHostingView(rootView: view.frame(width: 960, height: 640).environment(\.colorScheme, .light))
        window.contentView = host
        window.setFrame(NSRect(x: -10000, y: -10000, width: 960, height: 640), display: false)
        host.layoutSubtreeIfNeeded()
        let layoutTime = elapsedSeconds(start)

        let bitmapStart = ContinuousClock.now
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        let drawTime = elapsedSeconds(bitmapStart)
        let totalTime = elapsedSeconds(start)
        print(String(format: "[BENCH] UI %@: layout=%.4fs draw=%.4fs total=%.4fs", label, layoutTime, drawTime, totalTime))
    }

    AppPreferences.shared.splitDiff = false
    try await measureHosting(
        label: "ChunkDiffView Unified (8000 lines)",
        view: ChunkDiffView(prepared: prepared, chunkAction: { _ in }, lineAction: { _ in })
    )

    AppPreferences.shared.splitDiff = true
    try await measureHosting(
        label: "ChunkDiffView Split (8000 lines)",
        view: ChunkDiffView(prepared: prepared, chunkAction: { _ in }, lineAction: { _ in })
    )

    let mediumDiff = makeSyntheticLargeSwiftDiff(lineCount: 8_000)
    let preparedMediumDiff = PreparedDiff.make(mediumDiff, path: "Sources/GeneratedBig.swift")
    AppPreferences.shared.splitDiff = false
    try await measureHosting(
        label: "DiffView Unified (8000 lines)",
        view: DiffView(text: mediumDiff, title: "Sources/GeneratedBig.swift", initialPrepared: preparedMediumDiff)
    )

    AppPreferences.shared.splitDiff = true
    try await measureHosting(
        label: "DiffView Split (8000 lines)",
        view: DiffView(text: mediumDiff, title: "Sources/GeneratedBig.swift", initialPrepared: preparedMediumDiff)
    )

    let minifiedDiff = makeSyntheticMinifiedDiff(lineLength: 200_000)
    let preparedMinified = PreparedPatch.make(minifiedDiff, path: "dist/bundle.min.js")
    AppPreferences.shared.splitDiff = false
    try await measureHosting(
        label: "ChunkDiffView Unified (200KB minified line)",
        view: ChunkDiffView(prepared: preparedMinified, chunkAction: { _ in }, lineAction: { _ in })
    )

    AppPreferences.shared.splitDiff = true
    try await measureHosting(
        label: "ChunkDiffView Split (200KB minified line)",
        view: ChunkDiffView(prepared: preparedMinified, chunkAction: { _ in }, lineAction: { _ in })
    )

    #expect(!NSApplication.shared.isActive && NSApplication.shared.windows.filter(\.isVisible).isEmpty)
}
