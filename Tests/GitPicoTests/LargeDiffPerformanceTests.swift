import AppKit
import Foundation
import GitCore
import QuartzCore
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

@Test @MainActor func nativeDiffTableScrollsRecyclesAndSupportsSelectionAndCopy() async throws {
    let originalSplit = AppPreferences.shared.splitDiff
    defer { AppPreferences.shared.splitDiff = originalSplit }

    let largeDiff = makeSyntheticLargeSwiftDiff(lineCount: 12_000)
    let preparedPatch = PreparedPatch.make(largeDiff, path: "Sources/GeneratedBig.swift")

    func findViews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        if let match = root as? T { found.append(match) }
        for subview in root.subviews { found.append(contentsOf: findViews(of: type, in: subview)) }
        return found
    }

    func countSubviews(in root: NSView) -> Int {
        1 + root.subviews.reduce(0) { $0 + countSubviews(in: $1) }
    }

    for split in [false, true] {
        AppPreferences.shared.splitDiff = split
        var toggledCount = 0
        let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
        window.tabbingMode = .disallowed
        window.styleMask = [.borderless]
        window.contentMinSize = .zero
        window.appearance = NSAppearance(named: .aqua)
        defer { window.contentView = nil; window.close() }

        let host = NSHostingView(
            rootView: ChunkDiffView(
                prepared: preparedPatch,
                chunkAction: { _ in },
                lineAction: { _ in toggledCount += 1 }
            )
            .frame(width: 1100, height: 760)
            .environment(\.colorScheme, .light)
        )
        window.contentView = host
        window.setFrame(NSRect(x: -10000, y: -10000, width: 1100, height: 760), display: false)
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let scrollView = try #require(findViews(of: DiffScrollView.self, in: host).first)
        let tableView = try #require(findViews(of: DiffTableView.self, in: host).first)
        let delegate = try #require(tableView.interactionDelegate)

        #expect(tableView.numberOfRows > 5_000)
        let initialSubviews = countSubviews(in: host)

        let clipView = scrollView.contentView
        let maxY = max(0, tableView.bounds.height - clipView.bounds.height)
        for step in 1...40 {
            let nextY = min(maxY, CGFloat(step) * 400)
            clipView.scroll(to: NSPoint(x: 0, y: nextY))
            scrollView.reflectScrolledClipView(clipView)
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }
        let afterScrollSubviews = countSubviews(in: host)
        #expect(afterScrollSubviews < initialSubviews + 120)

        clipView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(clipView)
        host.layoutSubtreeIfNeeded()

        // Truncated hunks must not expose selectable gutters.
        let firstCodeRow = split ? 2 : 1
        let firstCodeRect = tableView.rect(ofRow: firstCodeRow)
        if case .selectableGutter = delegate.interactionTarget(at: NSPoint(x: firstCodeRect.minX + 12, y: firstCodeRect.midY)) {
            Issue.record("Truncated hunk should not allow line gutter selection")
        }

        let codeRow = firstCodeRow
        let codeRect = tableView.rect(ofRow: codeRow)
        let probeX = split ? codeRect.minX + 120 : codeRect.minX + 160
        let codePoint = NSPoint(x: probeX, y: codeRect.midY)
        let position = try #require(delegate.textPosition(at: codePoint, lockedColumn: nil))
        let wordSel = delegate.wordSelection(at: position)
        delegate.setTextSelection(wordSel)
        #expect(delegate.hasActiveTextSelection)
        let copiedWord = try #require(delegate.selectedTextForCopy())
        #expect(!copiedWord.isEmpty)

        delegate.selectAllText()
        let copiedAll = try #require(delegate.selectedTextForCopy())
        #expect(copiedAll.contains("computeItem_100"))

        tableView.cancelOperation(nil)
        #expect(!delegate.hasActiveTextSelection)
        #expect(toggledCount == 0)

        // Non-truncated patch must support gutter line selection in both Unified and Split modes.
        let smallPatch = PreparedPatch.make(makeSyntheticLargeSwiftDiff(lineCount: 40), path: "Sources/Small.swift")
        let smallHost = NSHostingView(
            rootView: ChunkDiffView(
                prepared: smallPatch,
                chunkAction: { _ in },
                lineAction: { _ in }
            )
            .frame(width: 1100, height: 600)
            .environment(\.colorScheme, .light)
        )
        window.contentView = smallHost
        smallHost.layoutSubtreeIfNeeded()
        CATransaction.flush()

        let smallTable = try #require(findViews(of: DiffTableView.self, in: smallHost).first)
        let smallDelegate = try #require(smallTable.interactionDelegate)
        var foundSelectableRow: Int?
        for row in 0..<min(smallTable.numberOfRows, 10) {
            let rect = smallTable.rect(ofRow: row)
            let gutterPoint = NSPoint(x: rect.minX + 12, y: rect.midY)
            if case .selectableGutter(let hunkID, let line) = smallDelegate.interactionTarget(at: gutterPoint) {
                foundSelectableRow = row
                smallDelegate.toggleSelectableLine(hunkID: hunkID, line: line)
                break
            }
        }
        #expect(foundSelectableRow != nil)
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

    func findScrollView(in root: NSView) -> NSScrollView? {
        if let scroll = root as? DiffScrollView { return scroll }
        for subview in root.subviews {
            if let match = findScrollView(in: subview) { return match }
        }
        return nil
    }

    func countSubviews(in root: NSView) -> Int {
        1 + root.subviews.reduce(0) { $0 + countSubviews(in: $1) }
    }

    func countSublayers(in layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        return 1 + (layer.sublayers ?? []).reduce(0) { $0 + countSublayers(in: $1) }
    }

    func measureScroll<Content: View>(label: String, view: Content, steps: Int, stepY: CGFloat, includeDraw: Bool) {
        let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
        window.tabbingMode = .disallowed
        window.styleMask = [.borderless]
        window.contentMinSize = .zero
        window.appearance = NSAppearance(named: .aqua)
        defer { window.contentView = nil; window.close() }

        let host = NSHostingView(rootView: view.frame(width: 1100, height: 760).environment(\.colorScheme, .light))
        window.contentView = host
        window.setFrame(NSRect(x: -10000, y: -10000, width: 1100, height: 760), display: false)
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()

        guard let scrollView = findScrollView(in: host) else {
            print("[SCROLL] \(label): NO DiffScrollView found")
            return
        }
        let clipView = scrollView.contentView
        let docHeight = scrollView.documentView?.bounds.height ?? 0
        let initSubviews = countSubviews(in: host)
        let initLayers = countSublayers(in: host.layer)
        let maxY = max(0, docHeight - clipView.bounds.height)
        let rep = includeDraw ? host.bitmapImageRepForCachingDisplay(in: host.bounds) : nil

        var frameMs: [Double] = []
        frameMs.reserveCapacity(steps)
        var y: CGFloat = 0
        for _ in 0..<steps {
            y = min(maxY, y + stepY)
            if y >= maxY { y = 0 }
            let frameStart = ContinuousClock.now
            clipView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clipView)
            host.layoutSubtreeIfNeeded()
            if let rep {
                host.cacheDisplay(in: host.bounds, to: rep)
            }
            CATransaction.flush()
            frameMs.append(elapsedSeconds(frameStart) * 1000.0)
        }
        let endSubviews = countSubviews(in: host)
        let endLayers = countSublayers(in: host.layer)
        let sorted = frameMs.sorted()
        let avg = frameMs.reduce(0, +) / Double(frameMs.count)
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let maxVal = sorted.last ?? 0
        let over8 = frameMs.filter { $0 > 8.33 }.count
        let over16 = frameMs.filter { $0 > 16.67 }.count
        print(String(
            format: "[SCROLL] %@: subviews=%d->%d layers=%d->%d avg=%.2fms p50=%.2fms p95=%.2fms max=%.2fms >8.3ms=%d/%d >16.7ms=%d/%d",
            label, initSubviews, endSubviews, initLayers, endLayers, avg, p50, p95, maxVal, over8, steps, over16, steps
        ))
    }

    let scrollDiff = makeSyntheticLargeSwiftDiff(lineCount: 12_000)
    let scrollPreparedPatch = PreparedPatch.make(scrollDiff, path: "Sources/GeneratedBig.swift")
    let scrollPreparedDiff = PreparedDiff.make(scrollDiff, path: "Sources/GeneratedBig.swift")

    AppPreferences.shared.splitDiff = false
    measureScroll(label: "ChunkDiffView Unified layout+flush (step=120)", view: ChunkDiffView(prepared: scrollPreparedPatch, chunkAction: { _ in }, lineAction: { _ in }), steps: 80, stepY: 120, includeDraw: false)
    measureScroll(label: "ChunkDiffView Unified layout+flush (fast step=400)", view: ChunkDiffView(prepared: scrollPreparedPatch, chunkAction: { _ in }, lineAction: { _ in }), steps: 80, stepY: 400, includeDraw: false)
    measureScroll(label: "ChunkDiffView Unified layout+draw+flush (step=120)", view: ChunkDiffView(prepared: scrollPreparedPatch, chunkAction: { _ in }, lineAction: { _ in }), steps: 80, stepY: 120, includeDraw: true)
    measureScroll(label: "ChunkDiffView Unified layout+draw+flush (fast step=400)", view: ChunkDiffView(prepared: scrollPreparedPatch, chunkAction: { _ in }, lineAction: { _ in }), steps: 80, stepY: 400, includeDraw: true)
    measureScroll(label: "DiffView Unified layout+flush (fast step=400)", view: DiffView(text: scrollDiff, title: "Sources/GeneratedBig.swift", initialPrepared: scrollPreparedDiff), steps: 80, stepY: 400, includeDraw: false)

    AppPreferences.shared.splitDiff = true
    measureScroll(label: "ChunkDiffView Split layout+flush (step=120)", view: ChunkDiffView(prepared: scrollPreparedPatch, chunkAction: { _ in }, lineAction: { _ in }), steps: 80, stepY: 120, includeDraw: false)
    measureScroll(label: "ChunkDiffView Split layout+flush (fast step=400)", view: ChunkDiffView(prepared: scrollPreparedPatch, chunkAction: { _ in }, lineAction: { _ in }), steps: 80, stepY: 400, includeDraw: false)
    measureScroll(label: "ChunkDiffView Split layout+draw+flush (step=120)", view: ChunkDiffView(prepared: scrollPreparedPatch, chunkAction: { _ in }, lineAction: { _ in }), steps: 80, stepY: 120, includeDraw: true)
    measureScroll(label: "ChunkDiffView Split layout+draw+flush (fast step=400)", view: ChunkDiffView(prepared: scrollPreparedPatch, chunkAction: { _ in }, lineAction: { _ in }), steps: 80, stepY: 400, includeDraw: true)
    measureScroll(label: "DiffView Split layout+flush (fast step=400)", view: DiffView(text: scrollDiff, title: "Sources/GeneratedBig.swift", initialPrepared: scrollPreparedDiff), steps: 80, stepY: 400, includeDraw: false)

    #expect(!NSApplication.shared.isActive && NSApplication.shared.windows.filter(\.isVisible).isEmpty)
}
