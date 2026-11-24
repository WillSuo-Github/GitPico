import AppKit
import CoreText
import GitCore
import SwiftUI
import UniformTypeIdentifiers

enum NativeDiffSource {
    case patch(
        prepared: PreparedPatch,
        showsColumnHeader: Bool,
        leftTitle: String,
        rightTitle: String,
        canSelectLines: Bool,
        hunkPrimaryActionTitle: String?,
        hunkSecondaryDestructiveTitle: String?,
        supportsHunkDrag: Bool,
        showsStashSelectionBar: Bool,
        truncationMessage: String
    )
    case diff(
        prepared: PreparedDiff,
        truncationMessage: String
    )

    var documentID: UUID {
        switch self {
        case .patch(let prepared, _, _, _, _, _, _, _, _, _): prepared.id
        case .diff(let prepared, _): prepared.id
        }
    }

    var fileHeaderFingerprint: String {
        switch self {
        case .patch(let prepared, _, let leftTitle, let rightTitle, _, _, _, _, _, _):
            let header: String
            if let newline = prepared.source.firstIndex(of: "\n") {
                header = String(prepared.source[..<newline])
            } else {
                header = String(prepared.source.prefix(256))
            }
            return "\(leftTitle)|\(rightTitle)|\(header)"
        case .diff(let prepared, _):
            return prepared.id.uuidString
        }
    }

    var maxUnifiedColumns: Int {
        switch self {
        case .patch(let prepared, _, _, _, _, _, _, _, _, _): prepared.maxUnifiedColumns
        case .diff(let prepared, _): prepared.maxUnifiedColumns
        }
    }

    var maxSplitLeftColumns: Int {
        switch self {
        case .patch(let prepared, _, _, _, _, _, _, _, _, _): prepared.maxSplitLeftColumns
        case .diff(let prepared, _): prepared.maxSplitLeftColumns
        }
    }

    var maxSplitRightColumns: Int {
        switch self {
        case .patch(let prepared, _, _, _, _, _, _, _, _, _): prepared.maxSplitRightColumns
        case .diff(let prepared, _): prepared.maxSplitRightColumns
        }
    }

    var isSelectableGutter: Bool {
        switch self {
        case .patch(let prepared, _, _, _, let canSelectLines, _, _, _, _, _):
            canSelectLines && prepared.patch.supportsChunkStaging
        case .diff:
            false
        }
    }

    var structureSignature: String {
        switch self {
        case .patch(let prepared, let showsColumnHeader, let leftTitle, let rightTitle, let canSelectLines, let primaryTitle, let secondaryTitle, let supportsHunkDrag, let showsStashSelectionBar, _):
            return "\(prepared.id.uuidString)|\(showsColumnHeader)|\(leftTitle)|\(rightTitle)|\(canSelectLines)|\(primaryTitle ?? "")|\(secondaryTitle ?? "")|\(supportsHunkDrag)|\(showsStashSelectionBar)"
        case .diff(let prepared, _):
            return prepared.id.uuidString
        }
    }
}

struct NativeDiffActions {
    var onToggleLine: ((Int, DiffLine) -> Void)? = nil
    var onPrimaryChunkAction: ((Int) -> Void)? = nil
    var onSecondaryChunkAction: ((Int) -> Void)? = nil
    var onHunkDragToken: ((Int) -> PicoDragToken?)? = nil
    var onClearStashSelection: (() -> Void)? = nil
    var onApplyStashLines: (() -> Void)? = nil
    var onStashLinesDragToken: (() -> PicoDragToken?)? = nil
}

struct NativeDiffTable: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    let source: NativeDiffSource
    let splitMode: Bool
    let fontSize: Double
    let selectedLines: Set<PatchLineID>
    let focusedLine: String?
    let findQuery: String
    let matchedLineIDs: Set<String>
    let findReveal: UUID
    let disabled: Bool
    let insets: EdgeInsets
    let actions: NativeDiffActions

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> DiffScrollView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: DiffScrollView, context: Context) {
        let targetAppearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if view.appearance?.name != targetAppearance?.name {
            view.appearance = targetAppearance
        }
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ view: DiffScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let scrollView = DiffScrollView()
        let tableView = DiffTableView()
        let mainColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))

        private var currentInput: NativeDiffTable?
        private var rows: [NativeDiffRow] = []
        private var rowIndexByLineKey: [String: Int] = [:]
        private var rowIndexByPatchLineID: [PatchLineID: Int] = [:]
        private var stashSelectionBarRowIndex: Int?
        private var palette: DiffRenderPalette
        private let lineCache = NSCache<NSNumber, CompiledCodeLine>()

        private var lastStructureSignature = ""
        private var lastFileHeaderFingerprint = ""
        private var lastSplitMode = false
        private var lastFontSize = 12.0
        private var lastSelectedLines: Set<PatchLineID> = []
        private var lastFocusedLine: String?
        private var lastFindQuery = ""
        private var lastMatchedLineIDs: Set<String> = []
        private var lastFindReveal = UUID()
        private var lastDisabled = false
        private var lastInsets = EdgeInsets()
        private var currentSplitLeftOffset: CGFloat = 0
        private var currentSplitRightOffset: CGFloat = 0
        private var currentUnifiedOriginX: CGFloat = 0
        private var currentViewportWidth: CGFloat = 0
        private var textSelection: DiffTextSelection?

        nonisolated(unsafe) private var clipBoundsObserver: NSObjectProtocol?
        nonisolated(unsafe) private var clipFrameObserver: NSObjectProtocol?

        override init() {
            palette = DiffRenderPalette.make(appearance: NSAppearance.currentDrawing(), fontSize: 12)
            super.init()
            lineCache.countLimit = 1024
        }

        deinit {
            if let clipBoundsObserver { NotificationCenter.default.removeObserver(clipBoundsObserver) }
            if let clipFrameObserver { NotificationCenter.default.removeObserver(clipFrameObserver) }
        }

        func teardown() {
            if let clipBoundsObserver {
                NotificationCenter.default.removeObserver(clipBoundsObserver)
                self.clipBoundsObserver = nil
            }
            if let clipFrameObserver {
                NotificationCenter.default.removeObserver(clipFrameObserver)
                self.clipFrameObserver = nil
            }
            scrollView.teardown()
        }

        func makeView() -> DiffScrollView {
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.contentView.postsFrameChangedNotifications = true

            tableView.addTableColumn(mainColumn)
            tableView.headerView = nil
            tableView.style = .plain
            tableView.backgroundColor = .clear
            tableView.intercellSpacing = .zero
            tableView.usesAutomaticRowHeights = false
            tableView.selectionHighlightStyle = .none
            tableView.allowsEmptySelection = true
            tableView.allowsMultipleSelection = false
            tableView.userInterfaceLayoutDirection = .leftToRight
            tableView.dataSource = self
            tableView.delegate = self
            tableView.interactionDelegate = self
            tableView.setAccessibilityLabel(String(localized: "Diff content"))

            scrollView.documentView = tableView
            scrollView.onSplitOffsetsChanged = { [weak self] leftOffset, rightOffset in
                self?.applySplitHorizontalOffsets(left: leftOffset, right: rightOffset)
            }
            scrollView.onViewportWidthChanged = { [weak self] width in
                self?.handleViewportWidthChanged(width)
            }

            clipBoundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleClipBoundsChanged()
                }
            }
            clipFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleClipFrameChanged()
                }
            }

            return scrollView
        }

        func update(_ input: NativeDiffTable) {
            let isFirstUpdate = currentInput == nil
            let previousInput = currentInput
            currentInput = input

            let resolvedAppearance = scrollView.appearance ?? scrollView.effectiveAppearance
            let appearanceChanged = palette.appearanceName != resolvedAppearance.name
            let fontChanged = abs(lastFontSize - input.fontSize) > 0.01
            if isFirstUpdate || appearanceChanged || fontChanged {
                palette = DiffRenderPalette.make(appearance: resolvedAppearance, fontSize: input.fontSize)
                lineCache.removeAllObjects()
            }

            let wasAtTop = isScrollAtTop()
            let insetsChanged = isFirstUpdate || lastInsets != input.insets
            if insetsChanged {
                lastInsets = input.insets
                let edgeInsets = NSEdgeInsets(top: input.insets.top, left: 0, bottom: input.insets.bottom, right: 0)
                scrollView.contentInsets = edgeInsets
                scrollView.scrollerInsets = edgeInsets
            }

            let structureSignature = input.source.structureSignature
            let fileHeaderFingerprint = input.source.fileHeaderFingerprint
            let modeChanged = isFirstUpdate || lastSplitMode != input.splitMode
            let documentChanged = isFirstUpdate || previousInput?.source.documentID != input.source.documentID
            let structureChanged = isFirstUpdate || modeChanged || lastStructureSignature != structureSignature

            if structureChanged {
                let isDifferentFile = isFirstUpdate || modeChanged || lastFileHeaderFingerprint != fileHeaderFingerprint
                lastStructureSignature = structureSignature
                lastFileHeaderFingerprint = fileHeaderFingerprint
                lastSplitMode = input.splitMode
                lastFontSize = input.fontSize
                lastSelectedLines = input.selectedLines
                lastFocusedLine = input.focusedLine
                lastFindQuery = input.findQuery
                lastMatchedLineIDs = input.matchedLineIDs
                lastDisabled = input.disabled

                clearTextSelection(redraw: false)
                lineCache.removeAllObjects()
                rebuildRows(from: input.source, splitMode: input.splitMode)

                scrollView.hasHorizontalScroller = !input.splitMode
                tableView.columnAutoresizingStyle = input.splitMode ? .uniformColumnAutoresizingStyle : .noColumnAutoresizing

                if isDifferentFile || documentChanged {
                    currentSplitLeftOffset = 0
                    currentSplitRightOffset = 0
                    currentUnifiedOriginX = 0
                    scrollView.resetSplitOffsets()
                }

                syncColumnAndSplitMetrics()
                tableView.reloadData()

                if isDifferentFile || wasAtTop || insetsChanged {
                    scrollToVerticalOffset(-scrollView.contentInsets.top, resetHorizontal: isDifferentFile)
                } else {
                    clampVerticalScrollPosition()
                }
            } else if fontChanged {
                lastFontSize = input.fontSize
                lastSelectedLines = input.selectedLines
                lastFocusedLine = input.focusedLine
                lastFindQuery = input.findQuery
                lastMatchedLineIDs = input.matchedLineIDs
                lastDisabled = input.disabled

                syncColumnAndSplitMetrics()
                tableView.reloadData()
                if wasAtTop || insetsChanged {
                    scrollToVerticalOffset(-scrollView.contentInsets.top, resetHorizontal: false)
                } else {
                    clampVerticalScrollPosition()
                }
            } else {
                var rowsToRefresh = IndexSet()
                var refreshAllVisible = false

                if appearanceChanged {
                    refreshAllVisible = true
                }

                if lastFindQuery != input.findQuery || lastMatchedLineIDs != input.matchedLineIDs {
                    lastFindQuery = input.findQuery
                    lastMatchedLineIDs = input.matchedLineIDs
                    lineCache.removeAllObjects()
                    refreshAllVisible = true
                }

                if lastSelectedLines != input.selectedLines {
                    let changedSelection = lastSelectedLines.symmetricDifference(input.selectedLines)
                    lastSelectedLines = input.selectedLines
                    for patchLineID in changedSelection {
                        if let rowIndex = rowIndexByPatchLineID[patchLineID] {
                            rowsToRefresh.insert(rowIndex)
                        }
                    }
                    if let stashBarIndex = stashSelectionBarRowIndex {
                        rowsToRefresh.insert(stashBarIndex)
                    }
                }

                if lastFocusedLine != input.focusedLine {
                    if let oldKey = lastFocusedLine, let oldRow = rowIndexByLineKey[oldKey] {
                        rowsToRefresh.insert(oldRow)
                    }
                    if let newKey = input.focusedLine, let newRow = rowIndexByLineKey[newKey] {
                        rowsToRefresh.insert(newRow)
                    }
                    lastFocusedLine = input.focusedLine
                }

                if lastDisabled != input.disabled {
                    lastDisabled = input.disabled
                    refreshAllVisible = true
                }

                if refreshAllVisible {
                    reconfigureVisibleRows()
                } else if !rowsToRefresh.isEmpty {
                    reconfigureVisibleRows(matching: rowsToRefresh)
                }

                if insetsChanged && wasAtTop {
                    scrollToVerticalOffset(-scrollView.contentInsets.top, resetHorizontal: false)
                }
            }

            if lastFindReveal != input.findReveal {
                lastFindReveal = input.findReveal
                if let focusedLine = input.focusedLine, let targetRow = rowIndexByLineKey[focusedLine] {
                    revealRowCentered(targetRow)
                }
            }
        }

        func handleAppearanceDidChange() {
            guard let input = currentInput else { return }
            let resolvedAppearance = scrollView.appearance ?? scrollView.effectiveAppearance
            guard palette.appearanceName != resolvedAppearance.name else { return }
            palette = DiffRenderPalette.make(appearance: resolvedAppearance, fontSize: input.fontSize)
            lineCache.removeAllObjects()
            reconfigureVisibleRows()
        }

        private func rebuildRows(from source: NativeDiffSource, splitMode: Bool) {
            rows.removeAll(keepingCapacity: true)
            rowIndexByLineKey.removeAll(keepingCapacity: true)
            rowIndexByPatchLineID.removeAll(keepingCapacity: true)
            stashSelectionBarRowIndex = nil

            switch source {
            case .patch(let prepared, let showsColumnHeader, let leftTitle, let rightTitle, let canSelectLines, _, _, _, let showsStashSelectionBar, let truncationMessage):
                if splitMode {
                    rows.reserveCapacity(prepared.splitItems.count + 2)
                    if showsColumnHeader {
                        rows.append(.splitColumnHeader(leftTitle: leftTitle, rightTitle: rightTitle))
                    }
                    if showsStashSelectionBar {
                        stashSelectionBarRowIndex = rows.count
                        rows.append(.stashSelectionBar)
                    }
                    for item in prepared.splitItems {
                        switch item {
                        case .hunkHeader(let preview):
                            rows.append(.hunkHeader(
                                hunkID: preview.hunk.id,
                                header: preview.hunk.header,
                                isTruncated: preview.isTruncated,
                                supportsChunkStaging: prepared.patch.supportsChunkStaging
                            ))
                        case .row(let hunkID, let row, let isSelectableHunk):
                            let rowIndex = rows.count
                            let selectable = canSelectLines && isSelectableHunk
                            let hunkCode = prepared.code[hunkID]
                            let leftKey = row.left.map { "\(hunkID):\($0.id)" }
                            let rightKey = row.right.map { "\(hunkID):\($0.id)" }
                            if let leftKey { rowIndexByLineKey[leftKey] = rowIndex }
                            if let rightKey { rowIndexByLineKey[rightKey] = rowIndex }
                            if let left = row.left, selectable {
                                rowIndexByPatchLineID[PatchLineID(hunk: hunkID, line: left.id)] = rowIndex
                            }
                            if let right = row.right, selectable {
                                rowIndexByPatchLineID[PatchLineID(hunk: hunkID, line: right.id)] = rowIndex
                            }
                            rows.append(.splitRow(
                                hunkID: hunkID,
                                row: row,
                                leftKey: leftKey,
                                rightKey: rightKey,
                                leftCode: row.left.flatMap { hunkCode?[$0.id] },
                                rightCode: row.right.flatMap { hunkCode?[$0.id] },
                                showsSelectionSlot: selectable
                            ))
                        case .truncationNotice:
                            rows.append(.truncationNotice(truncationMessage))
                        }
                    }
                } else {
                    rows.reserveCapacity(prepared.unifiedItems.count + 1)
                    if showsStashSelectionBar {
                        stashSelectionBarRowIndex = rows.count
                        rows.append(.stashSelectionBar)
                    }
                    for item in prepared.unifiedItems {
                        switch item {
                        case .hunkHeader(let preview):
                            rows.append(.hunkHeader(
                                hunkID: preview.hunk.id,
                                header: preview.hunk.header,
                                isTruncated: preview.isTruncated,
                                supportsChunkStaging: prepared.patch.supportsChunkStaging
                            ))
                        case .line(let hunkID, let line, let isSelectableHunk):
                            let rowIndex = rows.count
                            let selectable = canSelectLines && isSelectableHunk
                            let key = "\(hunkID):\(line.id)"
                            rowIndexByLineKey[key] = rowIndex
                            if selectable {
                                rowIndexByPatchLineID[PatchLineID(hunk: hunkID, line: line.id)] = rowIndex
                            }
                            rows.append(.unifiedLine(
                                key: key,
                                hunkID: hunkID,
                                line: line,
                                code: prepared.code[hunkID]?[line.id],
                                showsSelectionSlot: selectable
                            ))
                        case .truncationNotice:
                            rows.append(.truncationNotice(truncationMessage))
                        }
                    }
                }

            case .diff(let prepared, let truncationMessage):
                if splitMode {
                    rows.reserveCapacity(prepared.splitRows.count + (prepared.isTruncated ? 1 : 0))
                    for row in prepared.splitRows {
                        let rowIndex = rows.count
                        let leftKey = row.left.map { "line:\($0.id)" }
                        let rightKey = row.right.map { "line:\($0.id)" }
                        if let leftKey { rowIndexByLineKey[leftKey] = rowIndex }
                        if let rightKey { rowIndexByLineKey[rightKey] = rowIndex }
                        rows.append(.splitRow(
                            hunkID: nil,
                            row: row,
                            leftKey: leftKey,
                            rightKey: rightKey,
                            leftCode: row.left.flatMap { prepared.code[$0.id] },
                            rightCode: row.right.flatMap { prepared.code[$0.id] },
                            showsSelectionSlot: false
                        ))
                    }
                    if prepared.isTruncated {
                        rows.append(.truncationNotice(truncationMessage))
                    }
                } else {
                    rows.reserveCapacity(prepared.lines.count + 3)
                    rows.append(.verticalSpacer(7))
                    for line in prepared.lines {
                        let rowIndex = rows.count
                        let key = "line:\(line.id)"
                        rowIndexByLineKey[key] = rowIndex
                        rows.append(.unifiedLine(
                            key: key,
                            hunkID: nil,
                            line: line,
                            code: prepared.code[line.id],
                            showsSelectionSlot: false
                        ))
                    }
                    if prepared.isTruncated {
                        rows.append(.truncationNotice(truncationMessage))
                    }
                    rows.append(.verticalSpacer(7))
                }
            }
        }

        private func isScrollAtTop() -> Bool {
            scrollView.contentView.bounds.minY + scrollView.contentInsets.top <= 1.5
        }

        private func scrollToVerticalOffset(_ targetY: CGFloat, resetHorizontal: Bool) {
            let targetX = resetHorizontal ? 0 : scrollView.contentView.bounds.origin.x
            scrollView.contentView.scroll(to: NSPoint(x: targetX, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            handleClipBoundsChanged()
        }

        private func clampVerticalScrollPosition() {
            let clipBounds = scrollView.contentView.bounds
            let minY = -scrollView.contentInsets.top
            let maxY = max(minY, tableView.bounds.height - clipBounds.height + scrollView.contentInsets.bottom)
            let clampedY = min(maxY, max(minY, clipBounds.origin.y))
            if abs(clampedY - clipBounds.origin.y) > 0.5 {
                scrollToVerticalOffset(clampedY, resetHorizontal: false)
            }
        }

        private func revealRowCentered(_ rowIndex: Int) {
            guard rows.indices.contains(rowIndex) else { return }
            let rowRect = tableView.rect(ofRow: rowIndex)
            guard !rowRect.isEmpty else { return }
            let clipHeight = scrollView.contentView.bounds.height
            let visibleHeight = max(0, clipHeight - scrollView.contentInsets.top - scrollView.contentInsets.bottom)
            let minY = -scrollView.contentInsets.top
            let maxY = max(minY, tableView.bounds.height - clipHeight + scrollView.contentInsets.bottom)
            let centeredY = rowRect.midY - scrollView.contentInsets.top - visibleHeight / 2
            let targetY = min(maxY, max(minY, centeredY))
            scrollToVerticalOffset(targetY, resetHorizontal: false)
        }

        private func handleViewportWidthChanged(_ width: CGFloat) {
            guard abs(width - currentViewportWidth) > 0.25 else { return }
            currentViewportWidth = width
            syncColumnAndSplitMetrics()
            updateVisiblePinnedHeaders()
        }

        private func handleClipFrameChanged() {
            let width = scrollView.contentView.bounds.width
            if abs(width - currentViewportWidth) > 0.25 {
                currentViewportWidth = width
                syncColumnAndSplitMetrics()
                updateVisiblePinnedHeaders()
            }
        }

        private func handleClipBoundsChanged() {
            guard let input = currentInput, !input.splitMode else { return }
            let originX = max(0, scrollView.contentView.bounds.origin.x)
            let viewportWidth = scrollView.contentView.bounds.width
            if abs(originX - currentUnifiedOriginX) > 0.25 || abs(viewportWidth - currentViewportWidth) > 0.25 {
                currentUnifiedOriginX = originX
                currentViewportWidth = viewportWidth
                updateVisiblePinnedHeaders()
            }
        }

        private func syncColumnAndSplitMetrics() {
            guard let input = currentInput else { return }
            let viewportWidth = max(1, scrollView.contentView.bounds.width > 1 ? scrollView.contentView.bounds.width : scrollView.bounds.width)
            currentViewportWidth = viewportWidth

            if input.splitMode {
                mainColumn.minWidth = 0
                mainColumn.maxWidth = 1_000_000
                if abs(mainColumn.width - viewportWidth) > 0.5 {
                    mainColumn.width = viewportWidth
                }
                if abs(tableView.frame.width - viewportWidth) > 0.5 {
                    tableView.setFrameSize(NSSize(width: viewportWidth, height: tableView.frame.height))
                }
                let layout = DiffLayoutMetrics.splitLayout(
                    leftColumns: input.source.maxSplitLeftColumns,
                    rightColumns: input.source.maxSplitRightColumns,
                    fontSize: input.fontSize,
                    selectable: input.source.isSelectableGutter,
                    totalWidth: viewportWidth
                )
                scrollView.updateSplitHorizontalMetrics(
                    isSplit: true,
                    halfWidth: layout.halfWidth,
                    gutterWidth: layout.gutterWidth,
                    maxLeftOffset: layout.maxLeftOffset,
                    maxRightOffset: layout.maxRightOffset
                )
            } else {
                let desiredWidth = DiffLayoutMetrics.unifiedContentWidth(
                    columns: input.source.maxUnifiedColumns,
                    fontSize: input.fontSize,
                    selectable: input.source.isSelectableGutter,
                    minimumWidth: viewportWidth
                )
                mainColumn.minWidth = desiredWidth
                mainColumn.maxWidth = max(desiredWidth, 1_000_000)
                if abs(mainColumn.width - desiredWidth) > 0.5 {
                    mainColumn.width = desiredWidth
                }
                if abs(tableView.frame.width - desiredWidth) > 0.5 {
                    tableView.setFrameSize(NSSize(width: desiredWidth, height: tableView.frame.height))
                }
                scrollView.updateSplitHorizontalMetrics(
                    isSplit: false,
                    halfWidth: 0,
                    gutterWidth: 0,
                    maxLeftOffset: 0,
                    maxRightOffset: 0
                )
            }
        }

        private func applySplitHorizontalOffsets(left: CGFloat, right: CGFloat) {
            currentSplitLeftOffset = left
            currentSplitRightOffset = right
            let visibleRange = tableView.rows(in: tableView.visibleRect)
            guard visibleRange.location != NSNotFound, visibleRange.length > 0 else { return }
            let upperBound = min(rows.count, NSMaxRange(visibleRange))
            for rowIndex in visibleRange.location..<upperBound {
                if let splitCell = tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? SplitDiffCellView {
                    splitCell.setHorizontalOffsets(left: left, right: right)
                }
            }
        }

        private func updateVisiblePinnedHeaders() {
            let visibleRange = tableView.rows(in: tableView.visibleRect)
            guard visibleRange.location != NSNotFound, visibleRange.length > 0 else { return }
            let upperBound = min(rows.count, NSMaxRange(visibleRange))
            let originX = currentUnifiedOriginX
            let width = currentViewportWidth
            for rowIndex in visibleRange.location..<upperBound {
                guard let view = tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) else { continue }
                if let pinned = view as? HorizontallyPinnableCell {
                    pinned.setPinnedViewport(originX: originX, width: width)
                }
            }
        }

        private func reconfigureVisibleRows(matching targetRows: IndexSet? = nil) {
            let visibleRange = tableView.rows(in: tableView.visibleRect)
            guard visibleRange.location != NSNotFound, visibleRange.length > 0 else { return }
            let upperBound = min(rows.count, NSMaxRange(visibleRange))
            for rowIndex in visibleRange.location..<upperBound {
                if let targetRows, !targetRows.contains(rowIndex) { continue }
                guard let cell = tableView.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) else { continue }
                configureExistingCell(cell, at: rowIndex)
            }
        }

        private func compiledLine(for rowIndex: Int, sideTag: Int, line: DiffLine, code: DiffCodeLine?, query: String) -> CompiledCodeLine {
            let cacheKey = NSNumber(value: (rowIndex << 2) | sideTag)
            if let cached = lineCache.object(forKey: cacheKey) {
                return cached
            }
            let compiled = CompiledCodeLine.build(line: line, code: code, query: query, palette: palette)
            lineCache.setObject(compiled, forKey: cacheKey)
            return compiled
        }

        private func textSelectionRange(for rowIndex: Int, column: DiffTextColumn, maxLength: Int) -> Range<Int>? {
            guard let selection = textSelection, !selection.isEmpty, selection.column == column else { return nil }
            let lower = selection.lower
            let upper = selection.upper
            guard rowIndex >= lower.row, rowIndex <= upper.row else { return nil }
            let startOffset = rowIndex == lower.row ? min(maxLength, lower.utf16Offset) : 0
            let endOffset = rowIndex == upper.row ? min(maxLength, upper.utf16Offset) : maxLength
            if rowIndex < upper.row && startOffset == endOffset && maxLength == 0 {
                return 0..<0
            }
            guard endOffset >= startOffset else { return nil }
            return startOffset..<endOffset
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return palette.rowHeight }
            switch rows[row] {
            case .splitColumnHeader: return 24
            case .stashSelectionBar: return 30
            case .hunkHeader: return 30
            case .unifiedLine: return palette.rowHeight
            case .splitRow: return palette.rowHeight
            case .truncationNotice: return 36
            case .verticalSpacer(let height): return height
            }
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            false
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let input = currentInput, rows.indices.contains(row) else { return nil }
            switch rows[row] {
            case .splitColumnHeader(let leftTitle, let rightTitle):
                let cell = tableView.makeView(withIdentifier: DiffSplitHeaderCellView.reuseID, owner: nil) as? DiffSplitHeaderCellView ?? DiffSplitHeaderCellView()
                cell.configure(leftTitle: leftTitle, rightTitle: rightTitle, palette: palette)
                return cell

            case .stashSelectionBar:
                let cell = tableView.makeView(withIdentifier: DiffStashSelectionBarCellView.reuseID, owner: nil) as? DiffStashSelectionBarCellView ?? DiffStashSelectionBarCellView()
                configureStashSelectionBar(cell, input: input)
                return cell

            case .hunkHeader(let hunkID, let header, let isTruncated, let supportsChunkStaging):
                let cell = tableView.makeView(withIdentifier: DiffHunkHeaderCellView.reuseID, owner: nil) as? DiffHunkHeaderCellView ?? DiffHunkHeaderCellView()
                configureHunkHeader(cell, hunkID: hunkID, header: header, isTruncated: isTruncated, supportsChunkStaging: supportsChunkStaging, input: input)
                return cell

            case .unifiedLine(let key, let hunkID, let line, let code, let showsSelectionSlot):
                let cell = tableView.makeView(withIdentifier: UnifiedDiffCellView.reuseID, owner: nil) as? UnifiedDiffCellView ?? UnifiedDiffCellView()
                configureUnifiedCell(cell, rowIndex: row, key: key, hunkID: hunkID, line: line, code: code, showsSelectionSlot: showsSelectionSlot, input: input)
                return cell

            case .splitRow(let hunkID, let splitRow, let leftKey, let rightKey, let leftCode, let rightCode, let showsSelectionSlot):
                let cell = tableView.makeView(withIdentifier: SplitDiffCellView.reuseID, owner: nil) as? SplitDiffCellView ?? SplitDiffCellView()
                configureSplitCell(cell, rowIndex: row, hunkID: hunkID, splitRow: splitRow, leftKey: leftKey, rightKey: rightKey, leftCode: leftCode, rightCode: rightCode, showsSelectionSlot: showsSelectionSlot, input: input)
                return cell

            case .truncationNotice(let message):
                let cell = tableView.makeView(withIdentifier: DiffTruncationNoticeCellView.reuseID, owner: nil) as? DiffTruncationNoticeCellView ?? DiffTruncationNoticeCellView()
                cell.configure(message: message, palette: palette, isSplit: input.splitMode)
                cell.setPinnedViewport(originX: input.splitMode ? 0 : currentUnifiedOriginX, width: currentViewportWidth)
                return cell

            case .verticalSpacer:
                let spacerID = NSUserInterfaceItemIdentifier("diffSpacer")
                let cell = tableView.makeView(withIdentifier: spacerID, owner: nil) ?? NSView()
                cell.identifier = spacerID
                return cell
            }
        }

        private func configureExistingCell(_ cell: NSView, at rowIndex: Int) {
            guard let input = currentInput, rows.indices.contains(rowIndex) else { return }
            switch rows[rowIndex] {
            case .splitColumnHeader(let leftTitle, let rightTitle):
                if let headerCell = cell as? DiffSplitHeaderCellView {
                    headerCell.configure(leftTitle: leftTitle, rightTitle: rightTitle, palette: palette)
                }
            case .stashSelectionBar:
                if let barCell = cell as? DiffStashSelectionBarCellView {
                    configureStashSelectionBar(barCell, input: input)
                }
            case .hunkHeader(let hunkID, let header, let isTruncated, let supportsChunkStaging):
                if let hunkCell = cell as? DiffHunkHeaderCellView {
                    configureHunkHeader(hunkCell, hunkID: hunkID, header: header, isTruncated: isTruncated, supportsChunkStaging: supportsChunkStaging, input: input)
                }
            case .unifiedLine(let key, let hunkID, let line, let code, let showsSelectionSlot):
                if let unifiedCell = cell as? UnifiedDiffCellView {
                    configureUnifiedCell(unifiedCell, rowIndex: rowIndex, key: key, hunkID: hunkID, line: line, code: code, showsSelectionSlot: showsSelectionSlot, input: input)
                }
            case .splitRow(let hunkID, let splitRow, let leftKey, let rightKey, let leftCode, let rightCode, let showsSelectionSlot):
                if let splitCell = cell as? SplitDiffCellView {
                    configureSplitCell(splitCell, rowIndex: rowIndex, hunkID: hunkID, splitRow: splitRow, leftKey: leftKey, rightKey: rightKey, leftCode: leftCode, rightCode: rightCode, showsSelectionSlot: showsSelectionSlot, input: input)
                }
            case .truncationNotice(let message):
                if let noticeCell = cell as? DiffTruncationNoticeCellView {
                    noticeCell.configure(message: message, palette: palette, isSplit: input.splitMode)
                    noticeCell.setPinnedViewport(originX: input.splitMode ? 0 : currentUnifiedOriginX, width: currentViewportWidth)
                }
            case .verticalSpacer:
                break
            }
        }

        private func configureStashSelectionBar(_ cell: DiffStashSelectionBarCellView, input: NativeDiffTable) {
            cell.configure(
                selectedCount: input.selectedLines.count,
                isDisabled: input.disabled,
                palette: palette,
                isSplit: input.splitMode,
                onClear: { [weak self] in self?.currentInput?.actions.onClearStashSelection?() },
                onApply: { [weak self] in self?.currentInput?.actions.onApplyStashLines?() },
                onDragToken: { [weak self] in self?.currentInput?.actions.onStashLinesDragToken?() }
            )
            cell.setPinnedViewport(originX: input.splitMode ? 0 : currentUnifiedOriginX, width: currentViewportWidth)
        }

        private func configureHunkHeader(_ cell: DiffHunkHeaderCellView, hunkID: Int, header: String, isTruncated: Bool, supportsChunkStaging: Bool, input: NativeDiffTable) {
            var primaryTitle: String?
            var secondaryTitle: String?
            var supportsDrag = false
            if case .patch(_, _, _, _, _, let primary, let secondary, let drag, _, _) = input.source {
                primaryTitle = primary
                secondaryTitle = secondary
                supportsDrag = drag
            }
            let actionsEnabled = !input.disabled && supportsChunkStaging && !isTruncated
            cell.configure(
                hunkID: hunkID,
                header: header,
                primaryTitle: supportsChunkStaging ? primaryTitle : nil,
                secondaryDestructiveTitle: supportsChunkStaging ? secondaryTitle : nil,
                actionsEnabled: actionsEnabled,
                supportsDrag: supportsDrag && !input.disabled,
                palette: palette,
                isSplit: input.splitMode,
                onPrimary: { [weak self] targetHunkID in self?.currentInput?.actions.onPrimaryChunkAction?(targetHunkID) },
                onSecondary: { [weak self] targetHunkID in self?.currentInput?.actions.onSecondaryChunkAction?(targetHunkID) },
                onDragToken: { [weak self] targetHunkID in self?.currentInput?.actions.onHunkDragToken?(targetHunkID) }
            )
            cell.setPinnedViewport(originX: input.splitMode ? 0 : currentUnifiedOriginX, width: currentViewportWidth)
        }

        private func configureUnifiedCell(_ cell: UnifiedDiffCellView, rowIndex: Int, key: String, hunkID: Int?, line: DiffLine, code: DiffCodeLine?, showsSelectionSlot: Bool, input: NativeDiffTable) {
            let query = input.matchedLineIDs.contains(key) ? input.findQuery : ""
            let compiled = compiledLine(for: rowIndex, sideTag: 0, line: line, code: code, query: query)
            let isSelected = hunkID.map { input.selectedLines.contains(PatchLineID(hunk: $0, line: line.id)) } ?? false
            let isFocused = input.focusedLine == key
            let selectionRange = textSelectionRange(for: rowIndex, column: .unified, maxLength: compiled.displayUTF16Length)
            cell.configure(
                line: line,
                compiledLine: compiled,
                palette: palette,
                showsSelectionSlot: showsSelectionSlot,
                isSelected: isSelected,
                isFocused: isFocused,
                textSelectionRange: selectionRange,
                isTableFirstResponder: tableView.isActiveFirstResponder
            )
        }

        private func configureSplitCell(_ cell: SplitDiffCellView, rowIndex: Int, hunkID: Int?, splitRow: SplitDiffRow, leftKey: String?, rightKey: String?, leftCode: DiffCodeLine?, rightCode: DiffCodeLine?, showsSelectionSlot: Bool, input: NativeDiffTable) {
            let leftQuery = leftKey.map { input.matchedLineIDs.contains($0) ? input.findQuery : "" } ?? ""
            let rightQuery = rightKey.map { input.matchedLineIDs.contains($0) ? input.findQuery : "" } ?? ""
            let leftCompiled = splitRow.left.map { compiledLine(for: rowIndex, sideTag: 1, line: $0, code: leftCode, query: leftQuery) }
            let rightCompiled = splitRow.right.map { compiledLine(for: rowIndex, sideTag: 2, line: $0, code: rightCode, query: rightQuery) }
            let leftSelected = splitRow.left.flatMap { line in hunkID.map { input.selectedLines.contains(PatchLineID(hunk: $0, line: line.id)) } } ?? false
            let rightSelected = splitRow.right.flatMap { line in hunkID.map { input.selectedLines.contains(PatchLineID(hunk: $0, line: line.id)) } } ?? false
            let leftFocused = leftKey != nil && input.focusedLine == leftKey
            let rightFocused = rightKey != nil && input.focusedLine == rightKey
            let leftSelection = leftCompiled.flatMap { textSelectionRange(for: rowIndex, column: .splitLeft, maxLength: $0.displayUTF16Length) }
            let rightSelection = rightCompiled.flatMap { textSelectionRange(for: rowIndex, column: .splitRight, maxLength: $0.displayUTF16Length) }

            cell.configure(
                row: splitRow,
                leftCompiled: leftCompiled,
                rightCompiled: rightCompiled,
                palette: palette,
                showsSelectionSlot: showsSelectionSlot,
                leftSelected: leftSelected,
                rightSelected: rightSelected,
                leftFocused: leftFocused,
                rightFocused: rightFocused,
                leftOffset: currentSplitLeftOffset,
                rightOffset: currentSplitRightOffset,
                leftTextSelectionRange: leftSelection,
                rightTextSelectionRange: rightSelection,
                isTableFirstResponder: tableView.isActiveFirstResponder
            )
        }

        func clearTextSelection(redraw: Bool) {
            guard let existing = textSelection else { return }
            textSelection = nil
            if redraw {
                let lowerRow = max(0, existing.lower.row)
                let upperRow = min(rows.count - 1, existing.upper.row)
                if lowerRow <= upperRow {
                    reconfigureVisibleRows(matching: IndexSet(integersIn: lowerRow...upperRow))
                }
            }
        }

        func updateTextSelection(_ next: DiffTextSelection?) {
            let previous = textSelection
            guard previous != next else { return }
            textSelection = next

            var affected = IndexSet()
            if let previous, rows.indices.contains(previous.lower.row), rows.indices.contains(previous.upper.row) {
                affected.insert(integersIn: previous.lower.row...previous.upper.row)
            }
            if let next, rows.indices.contains(next.lower.row), rows.indices.contains(next.upper.row) {
                affected.insert(integersIn: next.lower.row...next.upper.row)
            }
            if !affected.isEmpty {
                reconfigureVisibleRows(matching: affected)
            }
        }
    }
}

extension NativeDiffTable.Coordinator: DiffTableInteractionDelegate {
    var hasActiveTextSelection: Bool {
        guard let selection = textSelection else { return false }
        return !selection.isEmpty
    }

    func interactionTarget(at tablePoint: NSPoint) -> DiffHitTarget {
        let rowIndex = tableView.row(at: tablePoint)
        guard rows.indices.contains(rowIndex) else { return .none }
        let rowRect = tableView.rect(ofRow: rowIndex)
        let localX = tablePoint.x - rowRect.minX

        switch rows[rowIndex] {
        case .unifiedLine(_, let hunkID, let line, _, let showsSelectionSlot):
            let slotWidth: CGFloat = showsSelectionSlot ? 25 : 0
            let gutterEnd = slotWidth + 90
            if showsSelectionSlot, let hunkID, line.kind == .addition || line.kind == .deletion, localX < gutterEnd {
                return .selectableGutter(hunkID: hunkID, line: line)
            }
            if localX >= gutterEnd {
                let hasSign = [.context, .addition, .deletion].contains(line.kind) && !line.text.isEmpty
                let codeOriginX = gutterEnd + 10 + (hasSign ? palette.charWidth : 0)
                return .code(row: rowIndex, column: .unified, codeLocalX: localX - codeOriginX)
            }
            return .none

        case .splitRow(let hunkID, let splitRow, _, _, _, _, let showsSelectionSlot):
            let halfWidth = floor((rowRect.width - 1) / 2)
            let rightOriginX = halfWidth + 1
            let gutterWidth: CGFloat = (showsSelectionSlot ? 25 : 0) + 52
            if localX < halfWidth {
                guard let leftLine = splitRow.left else { return .none }
                if showsSelectionSlot, let hunkID, leftLine.kind == .addition || leftLine.kind == .deletion, localX < gutterWidth {
                    return .selectableGutter(hunkID: hunkID, line: leftLine)
                }
                if localX >= gutterWidth {
                    return .code(row: rowIndex, column: .splitLeft, codeLocalX: localX - gutterWidth + currentSplitLeftOffset)
                }
                return .none
            } else if localX >= rightOriginX {
                let sideX = localX - rightOriginX
                guard let rightLine = splitRow.right else { return .none }
                if showsSelectionSlot, let hunkID, rightLine.kind == .addition || rightLine.kind == .deletion, sideX < gutterWidth {
                    return .selectableGutter(hunkID: hunkID, line: rightLine)
                }
                if sideX >= gutterWidth {
                    return .code(row: rowIndex, column: .splitRight, codeLocalX: sideX - gutterWidth + currentSplitRightOffset)
                }
                return .none
            }
            return .none

        default:
            return .none
        }
    }

    func toggleSelectableLine(hunkID: Int, line: DiffLine) {
        guard let input = currentInput, !input.disabled else { return }
        input.actions.onToggleLine?(hunkID, line)
    }

    func textPosition(at tablePoint: NSPoint, lockedColumn: DiffTextColumn?) -> DiffTextPosition? {
        guard !rows.isEmpty else { return nil }
        let rawRow = tableView.row(at: tablePoint)
        let clampedRow: Int
        if rawRow >= 0 {
            clampedRow = rawRow
        } else if tablePoint.y < 0 {
            clampedRow = 0
        } else {
            clampedRow = rows.count - 1
        }
        guard rows.indices.contains(clampedRow) else { return nil }
        let rowRect = tableView.rect(ofRow: clampedRow)
        let localX = tablePoint.x - rowRect.minX

        switch rows[clampedRow] {
        case .unifiedLine(let key, _, let line, let code, let showsSelectionSlot):
            let column: DiffTextColumn = .unified
            if let lockedColumn, lockedColumn != column { return nil }
            let slotWidth: CGFloat = showsSelectionSlot ? 25 : 0
            let hasSign = [.context, .addition, .deletion].contains(line.kind) && !line.text.isEmpty
            let codeOriginX = slotWidth + 90 + 10 + (hasSign ? palette.charWidth : 0)
            let compiled = compiledLineForInteraction(rowIndex: clampedRow, sideTag: 0, key: key, line: line, code: code)
            let offset = compiled.utf16Offset(atX: localX - codeOriginX)
            return DiffTextPosition(row: clampedRow, column: column, utf16Offset: offset)

        case .splitRow(_, let splitRow, let leftKey, let rightKey, let leftCode, let rightCode, let showsSelectionSlot):
            let halfWidth = floor((rowRect.width - 1) / 2)
            let rightOriginX = halfWidth + 1
            let gutterWidth: CGFloat = (showsSelectionSlot ? 25 : 0) + 52
            let resolvedColumn = lockedColumn ?? (localX < halfWidth ? .splitLeft : .splitRight)
            switch resolvedColumn {
            case .splitLeft:
                guard let leftLine = splitRow.left else {
                    return DiffTextPosition(row: clampedRow, column: .splitLeft, utf16Offset: 0)
                }
                let compiled = compiledLineForInteraction(rowIndex: clampedRow, sideTag: 1, key: leftKey, line: leftLine, code: leftCode)
                let offset = compiled.utf16Offset(atX: localX - gutterWidth + currentSplitLeftOffset)
                return DiffTextPosition(row: clampedRow, column: .splitLeft, utf16Offset: offset)
            case .splitRight:
                guard let rightLine = splitRow.right else {
                    return DiffTextPosition(row: clampedRow, column: .splitRight, utf16Offset: 0)
                }
                let compiled = compiledLineForInteraction(rowIndex: clampedRow, sideTag: 2, key: rightKey, line: rightLine, code: rightCode)
                let offset = compiled.utf16Offset(atX: localX - rightOriginX - gutterWidth + currentSplitRightOffset)
                return DiffTextPosition(row: clampedRow, column: .splitRight, utf16Offset: offset)
            case .unified:
                return nil
            }

        default:
            if let lockedColumn {
                return DiffTextPosition(row: clampedRow, column: lockedColumn, utf16Offset: 0)
            }
            return nil
        }
    }

    func wordSelection(at position: DiffTextPosition) -> DiffTextSelection {
        guard let compiled = compiledLine(at: position.row, column: position.column) else {
            return DiffTextSelection(anchor: position, head: position)
        }
        let range = compiled.wordRange(atUTF16Offset: position.utf16Offset)
        return DiffTextSelection(
            anchor: DiffTextPosition(row: position.row, column: position.column, utf16Offset: range.lowerBound),
            head: DiffTextPosition(row: position.row, column: position.column, utf16Offset: range.upperBound)
        )
    }

    func lineSelection(at position: DiffTextPosition) -> DiffTextSelection {
        let length = compiledLine(at: position.row, column: position.column)?.displayUTF16Length ?? 0
        return DiffTextSelection(
            anchor: DiffTextPosition(row: position.row, column: position.column, utf16Offset: 0),
            head: DiffTextPosition(row: position.row, column: position.column, utf16Offset: length)
        )
    }

    func extendSelection(anchorSelection: DiffTextSelection, to currentPosition: DiffTextPosition, clickCount: Int) -> DiffTextSelection {
        if clickCount >= 3 {
            let currentLine = lineSelection(at: currentPosition)
            if currentPosition < anchorSelection.anchor {
                return DiffTextSelection(anchor: anchorSelection.upper, head: currentLine.lower)
            }
            return DiffTextSelection(anchor: anchorSelection.lower, head: currentLine.upper)
        }
        if clickCount == 2 {
            let currentWord = wordSelection(at: currentPosition)
            if currentPosition < anchorSelection.anchor {
                return DiffTextSelection(anchor: anchorSelection.upper, head: currentWord.lower)
            }
            return DiffTextSelection(anchor: anchorSelection.lower, head: currentWord.upper)
        }
        return DiffTextSelection(anchor: anchorSelection.anchor, head: currentPosition)
    }

    func currentTextSelection() -> DiffTextSelection? {
        textSelection
    }

    func setTextSelection(_ selection: DiffTextSelection?) {
        updateTextSelection(selection)
    }

    func selectedTextForCopy() -> String? {
        guard let selection = textSelection, !selection.isEmpty else { return nil }
        let lower = selection.lower
        let upper = selection.upper
        let startRow = max(0, lower.row)
        let endRow = min(rows.count - 1, upper.row)
        guard startRow <= endRow else { return nil }

        var fragments: [String] = []
        fragments.reserveCapacity(endRow - startRow + 1)

        for rowIndex in startRow...endRow {
            if rowIndex > lower.row && rowIndex < upper.row {
                if let fullSource = rawSourceLine(at: rowIndex, column: selection.column) {
                    fragments.append(fullSource)
                }
            } else {
                guard let compiled = compiledLine(at: rowIndex, column: selection.column) else { continue }
                let startOffset = rowIndex == lower.row ? min(compiled.displayUTF16Length, lower.utf16Offset) : 0
                let endOffset = rowIndex == upper.row ? min(compiled.displayUTF16Length, upper.utf16Offset) : compiled.displayUTF16Length
                guard endOffset >= startOffset else { continue }
                if startOffset == 0 && endOffset == compiled.displayUTF16Length {
                    fragments.append(compiled.fullSource)
                } else {
                    fragments.append(compiled.substring(utf16Range: startOffset..<endOffset))
                }
            }
        }
        guard !fragments.isEmpty else { return nil }
        return fragments.joined(separator: "\n")
    }

    func selectAllText() {
        guard let input = currentInput else { return }
        let targetColumn: DiffTextColumn
        if input.splitMode {
            targetColumn = textSelection?.column ?? .splitRight
        } else {
            targetColumn = .unified
        }
        var firstRow: Int?
        var lastRow: Int?
        for (index, row) in rows.enumerated() {
            let hasContent: Bool
            switch (row, targetColumn) {
            case (.unifiedLine, .unified): hasContent = true
            case (.splitRow(_, let splitRow, _, _, _, _, _), .splitLeft): hasContent = splitRow.left != nil
            case (.splitRow(_, let splitRow, _, _, _, _, _), .splitRight): hasContent = splitRow.right != nil
            default: hasContent = false
            }
            if hasContent {
                if firstRow == nil { firstRow = index }
                lastRow = index
            }
        }
        guard let firstRow, let lastRow else { return }
        let lastLength = compiledLine(at: lastRow, column: targetColumn)?.displayUTF16Length ?? 0
        let anchor = DiffTextPosition(row: firstRow, column: targetColumn, utf16Offset: 0)
        let head = DiffTextPosition(row: lastRow, column: targetColumn, utf16Offset: lastLength)
        updateTextSelection(DiffTextSelection(anchor: anchor, head: head))
    }

    var hasSelectableTextRows: Bool {
        rows.contains { row in
            switch row {
            case .unifiedLine, .splitRow: return true
            default: return false
            }
        }
    }

    func fullSourceLine(at tablePoint: NSPoint) -> String? {
        switch interactionTarget(at: tablePoint) {
        case .code(let rowIndex, let column, _):
            return compiledLine(at: rowIndex, column: column)?.fullSource
        case .selectableGutter(_, let line):
            return CodeHighlighting.source(line)
        case .none:
            let rowIndex = tableView.row(at: tablePoint)
            guard rows.indices.contains(rowIndex) else { return nil }
            if case .unifiedLine(_, _, let line, let code, _) = rows[rowIndex] {
                return code?.source ?? CodeHighlighting.source(line)
            }
            return nil
        }
    }

    func handleFirstResponderChanged() {
        guard let selection = textSelection, !selection.isEmpty else { return }
        let lowerRow = max(0, selection.lower.row)
        let upperRow = min(rows.count - 1, selection.upper.row)
        if lowerRow <= upperRow {
            reconfigureVisibleRows(matching: IndexSet(integersIn: lowerRow...upperRow))
        }
    }

    func handleEffectiveAppearanceChanged() {
        handleAppearanceDidChange()
    }

    private func compiledLineForInteraction(rowIndex: Int, sideTag: Int, key: String?, line: DiffLine, code: DiffCodeLine?) -> CompiledCodeLine {
        let query: String
        if let input = currentInput, let key, input.matchedLineIDs.contains(key) {
            query = input.findQuery
        } else {
            query = ""
        }
        return compiledLine(for: rowIndex, sideTag: sideTag, line: line, code: code, query: query)
    }

    private func compiledLine(at rowIndex: Int, column: DiffTextColumn) -> CompiledCodeLine? {
        guard rows.indices.contains(rowIndex) else { return nil }
        switch (rows[rowIndex], column) {
        case (.unifiedLine(let key, _, let line, let code, _), .unified):
            return compiledLineForInteraction(rowIndex: rowIndex, sideTag: 0, key: key, line: line, code: code)
        case (.splitRow(_, let splitRow, let leftKey, _, let leftCode, _, _), .splitLeft):
            guard let leftLine = splitRow.left else { return nil }
            return compiledLineForInteraction(rowIndex: rowIndex, sideTag: 1, key: leftKey, line: leftLine, code: leftCode)
        case (.splitRow(_, let splitRow, _, let rightKey, _, let rightCode, _), .splitRight):
            guard let rightLine = splitRow.right else { return nil }
            return compiledLineForInteraction(rowIndex: rowIndex, sideTag: 2, key: rightKey, line: rightLine, code: rightCode)
        default:
            return nil
        }
    }

    private func rawSourceLine(at rowIndex: Int, column: DiffTextColumn) -> String? {
        guard rows.indices.contains(rowIndex) else { return nil }
        switch (rows[rowIndex], column) {
        case (.unifiedLine(_, _, let line, let code, _), .unified):
            return code?.source ?? CodeHighlighting.source(line)
        case (.splitRow(_, let splitRow, _, _, let leftCode, _, _), .splitLeft):
            guard let leftLine = splitRow.left else { return nil }
            return leftCode?.source ?? CodeHighlighting.source(leftLine)
        case (.splitRow(_, let splitRow, _, _, _, let rightCode, _), .splitRight):
            guard let rightLine = splitRow.right else { return nil }
            return rightCode?.source ?? CodeHighlighting.source(rightLine)
        default:
            return nil
        }
    }
}

private enum NativeDiffRow {
    case splitColumnHeader(leftTitle: String, rightTitle: String)
    case stashSelectionBar
    case hunkHeader(hunkID: Int, header: String, isTruncated: Bool, supportsChunkStaging: Bool)
    case unifiedLine(key: String, hunkID: Int?, line: DiffLine, code: DiffCodeLine?, showsSelectionSlot: Bool)
    case splitRow(hunkID: Int?, row: SplitDiffRow, leftKey: String?, rightKey: String?, leftCode: DiffCodeLine?, rightCode: DiffCodeLine?, showsSelectionSlot: Bool)
    case truncationNotice(String)
    case verticalSpacer(CGFloat)
}

enum DiffTextColumn: Equatable {
    case unified
    case splitLeft
    case splitRight
}

struct DiffTextPosition: Equatable, Comparable {
    let row: Int
    let column: DiffTextColumn
    let utf16Offset: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.row != rhs.row { return lhs.row < rhs.row }
        return lhs.utf16Offset < rhs.utf16Offset
    }
}

struct DiffTextSelection: Equatable {
    var anchor: DiffTextPosition
    var head: DiffTextPosition

    var column: DiffTextColumn { anchor.column }
    var lower: DiffTextPosition { min(anchor, head) }
    var upper: DiffTextPosition { max(anchor, head) }
    var isEmpty: Bool { anchor == head }
}

enum DiffHitTarget {
    case none
    case selectableGutter(hunkID: Int, line: DiffLine)
    case code(row: Int, column: DiffTextColumn, codeLocalX: CGFloat)
}

@MainActor protocol DiffTableInteractionDelegate: AnyObject {
    var hasActiveTextSelection: Bool { get }
    var hasSelectableTextRows: Bool { get }
    func interactionTarget(at tablePoint: NSPoint) -> DiffHitTarget
    func toggleSelectableLine(hunkID: Int, line: DiffLine)
    func textPosition(at tablePoint: NSPoint, lockedColumn: DiffTextColumn?) -> DiffTextPosition?
    func wordSelection(at position: DiffTextPosition) -> DiffTextSelection
    func lineSelection(at position: DiffTextPosition) -> DiffTextSelection
    func extendSelection(anchorSelection: DiffTextSelection, to currentPosition: DiffTextPosition, clickCount: Int) -> DiffTextSelection
    func currentTextSelection() -> DiffTextSelection?
    func setTextSelection(_ selection: DiffTextSelection?)
    func selectedTextForCopy() -> String?
    func selectAllText()
    func fullSourceLine(at tablePoint: NSPoint) -> String?
    func handleFirstResponderChanged()
    func handleEffectiveAppearanceChanged()
}

@MainActor private protocol HorizontallyPinnableCell: AnyObject {
    func setPinnedViewport(originX: CGFloat, width: CGFloat)
}

@MainActor private struct DiffRenderPalette {
    let appearanceName: NSAppearance.Name
    let fontSize: Double
    let rowHeight: CGFloat
    let charWidth: CGFloat
    let baselineY: CGFloat
    let highlightTop: CGFloat
    let highlightHeight: CGFloat
    let monoRegular: NSFont
    let monoBold: NSFont
    let paragraphStyle: NSParagraphStyle

    let primaryText: NSColor
    let secondaryText: NSColor
    let tertiaryText: NSColor
    let keywordText: NSColor
    let stringText: NSColor
    let numberText: NSColor
    let commentText: NSColor
    let additionColor: NSColor
    let deletionColor: NSColor
    let accentColor: NSColor
    let separatorColor: NSColor

    let unifiedAdditionBg: CGColor
    let unifiedDeletionBg: CGColor
    let unifiedHunkBg: CGColor
    let unifiedGutterAdditionBg: CGColor
    let unifiedGutterDeletionBg: CGColor
    let unifiedSelectedBg: CGColor

    let splitAdditionBg: CGColor
    let splitDeletionBg: CGColor
    let splitHunkBg: CGColor
    let splitEmptyBg: CGColor
    let splitSelectedBg: CGColor

    let changeHighlightBg: CGColor
    let searchHighlightBg: CGColor
    let activeTextSelectionBg: CGColor
    let inactiveTextSelectionBg: CGColor

    let hunkHeaderBg: CGColor
    let hunkHeaderDivider: CGColor
    let hunkHeaderText: NSColor
    let stashBarBg: CGColor
    let unifiedGutterAdditionText: NSColor
    let unifiedGutterDeletionText: NSColor
    let hunkLineText: NSColor

    let plusSignLine: CTLine
    let minusSignLine: CTLine
    let spaceSignLine: CTLine
    let checkboxSelectedImage: NSImage?
    let checkboxUnselectedImage: NSImage?

    static func make(appearance: NSAppearance, fontSize: Double) -> DiffRenderPalette {
        var resolved: DiffRenderPalette!
        appearance.performAsCurrentDrawingAppearance {
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rowHeight = DiffLayoutMetrics.unifiedRowHeight(fontSize: fontSize)
            let charWidth = DiffLayoutMetrics.monospaceCharacterWidth(fontSize: fontSize)
            let monoRegular = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let monoBold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

            let ascent = monoRegular.ascender
            let descent = -monoRegular.descender
            let textHeight = ascent + descent
            let topPadding = (rowHeight - textHeight) / 2
            let baselineY = ((topPadding + ascent) * 2).rounded() / 2
            let highlightTop = max(0, floor(topPadding - 1))
            let highlightHeight = min(rowHeight - highlightTop, ceil(textHeight + 2))

            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = []
            paragraph.defaultTabInterval = charWidth * 4

            let primaryText = NSColor.labelColor.usingColorSpace(.sRGB) ?? NSColor.labelColor
            let secondaryText = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? NSColor.secondaryLabelColor
            let tertiaryText = NSColor.tertiaryLabelColor.usingColorSpace(.sRGB) ?? NSColor.tertiaryLabelColor
            let keywordText = isDark
                ? NSColor(srgbRed: 0.82, green: 0.64, blue: 0.98, alpha: 1)
                : NSColor(srgbRed: 0.42, green: 0.16, blue: 0.65, alpha: 1)
            let stringText = isDark
                ? NSColor(srgbRed: 0.96, green: 0.73, blue: 0.61, alpha: 1)
                : NSColor(srgbRed: 0.62, green: 0.20, blue: 0.09, alpha: 1)
            let numberText = isDark
                ? NSColor(srgbRed: 0.56, green: 0.75, blue: 1.0, alpha: 1)
                : NSColor(srgbRed: 0.09, green: 0.34, blue: 0.68, alpha: 1)
            let additionColor = NSColor(srgbRed: 0.20, green: 0.66, blue: 0.36, alpha: 1)
            let deletionColor = NSColor(srgbRed: 0.90, green: 0.27, blue: 0.27, alpha: 1)
            let accentColor = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.controlAccentColor
            let separatorColor = NSColor.separatorColor.usingColorSpace(.sRGB) ?? NSColor.separatorColor
            let searchYellow = NSColor.systemYellow.usingColorSpace(.sRGB) ?? NSColor.systemYellow
            let activeSelection = NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB) ?? NSColor.selectedTextBackgroundColor
            let inactiveSelection = NSColor.unemphasizedSelectedTextBackgroundColor.usingColorSpace(.sRGB) ?? NSColor.unemphasizedSelectedTextBackgroundColor
            let barSurface = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? NSColor.windowBackgroundColor

            let signAttributes: [NSAttributedString.Key: Any] = [
                .font: monoRegular,
                .foregroundColor: secondaryText
            ]
            let plusSignLine = CTLineCreateWithAttributedString(NSAttributedString(string: "+", attributes: signAttributes))
            let minusSignLine = CTLineCreateWithAttributedString(NSAttributedString(string: "-", attributes: signAttributes))
            let spaceSignLine = CTLineCreateWithAttributedString(NSAttributedString(string: " ", attributes: signAttributes))

            let selectedSymbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                .applying(.init(paletteColors: [accentColor]))
            let unselectedSymbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                .applying(.init(paletteColors: [secondaryText.withAlphaComponent(0.55)]))
            let checkboxSelectedImage = NSImage(systemSymbolName: "checkmark.square.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(selectedSymbolConfig)
            let checkboxUnselectedImage = NSImage(systemSymbolName: "square", accessibilityDescription: nil)?
                .withSymbolConfiguration(unselectedSymbolConfig)

            resolved = DiffRenderPalette(
                appearanceName: appearance.name,
                fontSize: fontSize,
                rowHeight: rowHeight,
                charWidth: charWidth,
                baselineY: baselineY,
                highlightTop: highlightTop,
                highlightHeight: highlightHeight,
                monoRegular: monoRegular,
                monoBold: monoBold,
                paragraphStyle: paragraph,
                primaryText: primaryText,
                secondaryText: secondaryText,
                tertiaryText: tertiaryText,
                keywordText: keywordText,
                stringText: stringText,
                numberText: numberText,
                commentText: secondaryText,
                additionColor: additionColor,
                deletionColor: deletionColor,
                accentColor: accentColor,
                separatorColor: separatorColor,
                unifiedAdditionBg: additionColor.withAlphaComponent(0.11).cgColor,
                unifiedDeletionBg: deletionColor.withAlphaComponent(0.11).cgColor,
                unifiedHunkBg: accentColor.withAlphaComponent(0.06).cgColor,
                unifiedGutterAdditionBg: additionColor.withAlphaComponent(0.10).cgColor,
                unifiedGutterDeletionBg: deletionColor.withAlphaComponent(0.10).cgColor,
                unifiedSelectedBg: accentColor.withAlphaComponent(0.23).cgColor,
                splitAdditionBg: additionColor.withAlphaComponent(0.12).cgColor,
                splitDeletionBg: deletionColor.withAlphaComponent(0.12).cgColor,
                splitHunkBg: accentColor.withAlphaComponent(0.06).cgColor,
                splitEmptyBg: secondaryText.withAlphaComponent(0.05).cgColor,
                splitSelectedBg: accentColor.withAlphaComponent(0.25).cgColor,
                changeHighlightBg: accentColor.withAlphaComponent(0.22).cgColor,
                searchHighlightBg: searchYellow.withAlphaComponent(0.45).cgColor,
                activeTextSelectionBg: activeSelection.cgColor,
                inactiveTextSelectionBg: inactiveSelection.cgColor,
                hunkHeaderBg: accentColor.withAlphaComponent(0.06).cgColor,
                hunkHeaderDivider: separatorColor.withAlphaComponent(0.6).cgColor,
                hunkHeaderText: accentColor.withAlphaComponent(0.85),
                stashBarBg: barSurface.cgColor,
                unifiedGutterAdditionText: additionColor.withAlphaComponent(0.9),
                unifiedGutterDeletionText: deletionColor.withAlphaComponent(0.9),
                hunkLineText: accentColor.withAlphaComponent(0.9),
                plusSignLine: plusSignLine,
                minusSignLine: minusSignLine,
                spaceSignLine: spaceSignLine,
                checkboxSelectedImage: checkboxSelectedImage,
                checkboxUnselectedImage: checkboxUnselectedImage
            )
        }
        return resolved
    }
}

@MainActor private final class CompiledCodeLine {
    let ctLine: CTLine
    let displayText: String
    let fullSource: String
    let displayUTF16Length: Int
    let changeSpans: [(CGFloat, CGFloat)]
    let searchSpans: [(CGFloat, CGFloat)]
    let typographicWidth: CGFloat

    private init(
        ctLine: CTLine,
        displayText: String,
        fullSource: String,
        displayUTF16Length: Int,
        changeSpans: [(CGFloat, CGFloat)],
        searchSpans: [(CGFloat, CGFloat)],
        typographicWidth: CGFloat
    ) {
        self.ctLine = ctLine
        self.displayText = displayText
        self.fullSource = fullSource
        self.displayUTF16Length = displayUTF16Length
        self.changeSpans = changeSpans
        self.searchSpans = searchSpans
        self.typographicWidth = typographicWidth
    }

    static func build(line: DiffLine, code: DiffCodeLine?, query: String, palette: DiffRenderPalette) -> CompiledCodeLine {
        let fullSource = code?.source ?? CodeHighlighting.source(line)
        let baseColor: NSColor
        switch line.kind {
        case .metadata: baseColor = palette.secondaryText
        case .hunk: baseColor = palette.hunkLineText
        default: baseColor = palette.primaryText
        }

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: palette.monoRegular,
            .foregroundColor: baseColor,
            .paragraphStyle: palette.paragraphStyle
        ]

        if fullSource.isEmpty {
            let emptyLine = CTLineCreateWithAttributedString(NSAttributedString(string: " ", attributes: baseAttributes))
            return CompiledCodeLine(
                ctLine: emptyLine,
                displayText: "",
                fullSource: "",
                displayUTF16Length: 0,
                changeSpans: [],
                searchSpans: [],
                typographicWidth: 0
            )
        }

        let slice = DiffCodeText.displayedSlice(of: fullSource)
        let displayText = slice.text
        let utf16Limit = slice.utf16Limit
        let searchMatches = query.isEmpty ? [] : CodeHighlighting.matches(displayText, query: query)
        let syntaxSpans = code?.syntax ?? []
        let changeRanges = code?.changes ?? []

        let attributed = NSMutableAttributedString(string: displayText, attributes: baseAttributes)

        for span in syntaxSpans {
            let raw = span.range
            guard raw.location < utf16Limit else { break }
            let clampedEnd = min(utf16Limit, NSMaxRange(raw))
            guard clampedEnd > raw.location else { continue }
            let range = NSRange(location: raw.location, length: clampedEnd - raw.location)
            let color: NSColor
            switch span.kind {
            case .keyword: color = palette.keywordText
            case .string: color = palette.stringText
            case .comment: color = palette.commentText
            case .number: color = palette.numberText
            }
            attributed.addAttribute(.foregroundColor, value: color, range: range)
        }

        for raw in changeRanges {
            guard raw.location < utf16Limit else { break }
            let clampedEnd = min(utf16Limit, NSMaxRange(raw))
            guard clampedEnd > raw.location else { continue }
            let range = NSRange(location: raw.location, length: clampedEnd - raw.location)
            attributed.addAttribute(.font, value: palette.monoBold, range: range)
        }

        for raw in searchMatches {
            guard raw.location < utf16Limit else { break }
            let clampedEnd = min(utf16Limit, NSMaxRange(raw))
            guard clampedEnd > raw.location else { continue }
            let range = NSRange(location: raw.location, length: clampedEnd - raw.location)
            attributed.addAttribute(.foregroundColor, value: palette.primaryText, range: range)
        }

        if slice.omittedCharacters > 0 {
            let suffix = NSAttributedString(
                string: " … (\(slice.omittedCharacters) chars omitted)",
                attributes: [
                    .font: palette.monoRegular,
                    .foregroundColor: palette.secondaryText,
                    .paragraphStyle: palette.paragraphStyle
                ]
            )
            attributed.append(suffix)
        }

        let ctLine = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))

        var changeSpans: [(CGFloat, CGFloat)] = []
        if !changeRanges.isEmpty {
            changeSpans.reserveCapacity(changeRanges.count)
            for raw in changeRanges {
                guard raw.location < utf16Limit else { break }
                let clampedEnd = min(utf16Limit, NSMaxRange(raw))
                guard clampedEnd > raw.location else { continue }
                let minX = CTLineGetOffsetForStringIndex(ctLine, raw.location, nil)
                let maxX = CTLineGetOffsetForStringIndex(ctLine, clampedEnd, nil)
                if maxX > minX { changeSpans.append((minX, maxX)) }
            }
        }

        var searchSpans: [(CGFloat, CGFloat)] = []
        if !searchMatches.isEmpty {
            searchSpans.reserveCapacity(searchMatches.count)
            for raw in searchMatches {
                guard raw.location < utf16Limit else { break }
                let clampedEnd = min(utf16Limit, NSMaxRange(raw))
                guard clampedEnd > raw.location else { continue }
                let minX = CTLineGetOffsetForStringIndex(ctLine, raw.location, nil)
                let maxX = CTLineGetOffsetForStringIndex(ctLine, clampedEnd, nil)
                if maxX > minX { searchSpans.append((minX, maxX)) }
            }
        }

        return CompiledCodeLine(
            ctLine: ctLine,
            displayText: displayText,
            fullSource: fullSource,
            displayUTF16Length: utf16Limit,
            changeSpans: changeSpans,
            searchSpans: searchSpans,
            typographicWidth: width
        )
    }

    func utf16Offset(atX localX: CGFloat) -> Int {
        guard displayUTF16Length > 0, localX > 0 else { return 0 }
        let raw = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: localX, y: 0))
        guard raw != kCFNotFound else { return displayUTF16Length }
        let clamped = max(0, min(displayUTF16Length, raw))
        return alignUTF16Offset(clamped)
    }

    func xOffset(forUTF16Index index: Int) -> CGFloat {
        guard displayUTF16Length > 0 else { return 0 }
        let clamped = max(0, min(displayUTF16Length, index))
        return CTLineGetOffsetForStringIndex(ctLine, clamped, nil)
    }

    func substring(utf16Range: Range<Int>) -> String {
        guard displayUTF16Length > 0 else { return "" }
        let lower = alignUTF16Offset(max(0, min(displayUTF16Length, utf16Range.lowerBound)))
        let upper = alignUTF16Offset(max(lower, min(displayUTF16Length, utf16Range.upperBound)))
        guard upper > lower else { return "" }
        return (displayText as NSString).substring(with: NSRange(location: lower, length: upper - lower))
    }

    func wordRange(atUTF16Offset offset: Int) -> Range<Int> {
        let total = displayUTF16Length
        guard total > 0 else { return 0..<0 }
        let nsString = displayText as NSString
        let probe = min(total - 1, max(0, offset))
        let unit = nsString.character(at: probe)

        func classify(_ codeUnit: unichar) -> Int {
            if codeUnit == 0x20 || codeUnit == 0x09 { return 0 }
            if (codeUnit >= 48 && codeUnit <= 57) ||
                (codeUnit >= 65 && codeUnit <= 90) ||
                (codeUnit >= 97 && codeUnit <= 122) ||
                codeUnit == 95 ||
                codeUnit >= 0x80 {
                return 1
            }
            return 2
        }

        let targetKind = classify(unit)
        var start = probe
        while start > 0 && classify(nsString.character(at: start - 1)) == targetKind {
            start -= 1
        }
        var end = probe + 1
        while end < total && classify(nsString.character(at: end)) == targetKind {
            end += 1
        }
        return alignUTF16Offset(start)..<alignUTF16Offset(end)
    }

    private func alignUTF16Offset(_ offset: Int) -> Int {
        guard offset > 0 && offset < displayUTF16Length else { return offset }
        let nsString = displayText as NSString
        let unit = nsString.character(at: offset)
        if unit >= 0xDC00 && unit <= 0xDFFF {
            return offset - 1
        }
        return offset
    }
}

private func makeLineNumberCTLine(_ number: Int, font: NSFont, color: NSColor) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: String(number), attributes: attributes))
}

private func drawCTLine(_ line: CTLine, at origin: CGPoint, in context: CGContext) {
    context.saveGState()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = origin
    CTLineDraw(line, context)
    context.restoreGState()
}

private final class UnifiedDiffCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("unifiedDiffCell")

    private var line: DiffLine?
    private var compiledLine: CompiledCodeLine?
    private var palette: DiffRenderPalette?
    private var showsSelectionSlot = false
    private var isSelected = false
    private var isFocused = false
    private var textSelectionRange: Range<Int>?
    private var isTableFirstResponder = false
    private var oldNumberLine: CTLine?
    private var newNumberLine: CTLine?
    private var cachedOldNumber: Int?
    private var cachedNewNumber: Int?
    private var cachedNumberAppearance: NSAppearance.Name?
    private var cachedNumberFontSize: Double = 0
    private var cachedNumberKind: DiffLine.Kind?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseID
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(
        line: DiffLine,
        compiledLine: CompiledCodeLine,
        palette: DiffRenderPalette,
        showsSelectionSlot: Bool,
        isSelected: Bool,
        isFocused: Bool,
        textSelectionRange: Range<Int>?,
        isTableFirstResponder: Bool
    ) {
        self.line = line
        self.compiledLine = compiledLine
        self.palette = palette
        self.showsSelectionSlot = showsSelectionSlot
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.textSelectionRange = textSelectionRange
        self.isTableFirstResponder = isTableFirstResponder

        let numbersNeedRebuild = cachedOldNumber != line.oldNumber ||
            cachedNewNumber != line.newNumber ||
            cachedNumberAppearance != palette.appearanceName ||
            abs(cachedNumberFontSize - palette.fontSize) > 0.01 ||
            cachedNumberKind != line.kind
        if numbersNeedRebuild {
            cachedOldNumber = line.oldNumber
            cachedNewNumber = line.newNumber
            cachedNumberAppearance = palette.appearanceName
            cachedNumberFontSize = palette.fontSize
            cachedNumberKind = line.kind
            let numberColor: NSColor
            switch line.kind {
            case .addition: numberColor = palette.unifiedGutterAdditionText
            case .deletion: numberColor = palette.unifiedGutterDeletionText
            default: numberColor = palette.tertiaryText
            }
            oldNumberLine = line.oldNumber.map { makeLineNumberCTLine($0, font: palette.monoRegular, color: numberColor) }
            newNumberLine = line.newNumber.map { makeLineNumberCTLine($0, font: palette.monoRegular, color: numberColor) }
        }

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let line,
              let compiledLine,
              let palette else { return }

        let rowRect = bounds
        let slotWidth: CGFloat = showsSelectionSlot ? 25 : 0
        let gutterEnd = slotWidth + 90
        let isChange = line.kind == .addition || line.kind == .deletion

        if isSelected {
            context.setFillColor(palette.unifiedSelectedBg)
            context.fill(rowRect)
        }

        switch line.kind {
        case .addition:
            context.setFillColor(palette.unifiedAdditionBg)
            context.fill(CGRect(x: slotWidth, y: 0, width: rowRect.width - slotWidth, height: rowRect.height))
            context.setFillColor(palette.unifiedGutterAdditionBg)
            context.fill(CGRect(x: slotWidth, y: 0, width: 90, height: rowRect.height))
        case .deletion:
            context.setFillColor(palette.unifiedDeletionBg)
            context.fill(CGRect(x: slotWidth, y: 0, width: rowRect.width - slotWidth, height: rowRect.height))
            context.setFillColor(palette.unifiedGutterDeletionBg)
            context.fill(CGRect(x: slotWidth, y: 0, width: 90, height: rowRect.height))
        case .hunk:
            context.setFillColor(palette.unifiedHunkBg)
            context.fill(CGRect(x: slotWidth, y: 0, width: rowRect.width - slotWidth, height: rowRect.height))
        default:
            break
        }

        if isChange {
            context.setFillColor((line.kind == .addition ? palette.additionColor : palette.deletionColor).cgColor)
            context.fill(CGRect(x: slotWidth, y: 0, width: 2, height: rowRect.height))
        }

        if showsSelectionSlot && isChange {
            let checkboxImage = isSelected ? palette.checkboxSelectedImage : palette.checkboxUnselectedImage
            if let checkboxImage {
                let imageSize = checkboxImage.size
                let imageRect = NSRect(
                    x: floor((25 - imageSize.width) / 2),
                    y: floor((rowRect.height - imageSize.height) / 2),
                    width: imageSize.width,
                    height: imageSize.height
                )
                checkboxImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }

        let baselineY = palette.baselineY
        if let oldNumberLine {
            let width = CGFloat(CTLineGetTypographicBounds(oldNumberLine, nil, nil, nil))
            drawCTLine(oldNumberLine, at: CGPoint(x: slotWidth + 38 - width, y: baselineY), in: context)
        }
        if let newNumberLine {
            let width = CGFloat(CTLineGetTypographicBounds(newNumberLine, nil, nil, nil))
            drawCTLine(newNumberLine, at: CGPoint(x: slotWidth + 38 + 6 + 38 - width, y: baselineY), in: context)
        }

        var codeOriginX = gutterEnd + 10
        if [.context, .addition, .deletion].contains(line.kind), let firstScalar = line.text.utf8.first {
            let signLine: CTLine
            if firstScalar == 43 { signLine = palette.plusSignLine }
            else if firstScalar == 45 { signLine = palette.minusSignLine }
            else { signLine = palette.spaceSignLine }
            drawCTLine(signLine, at: CGPoint(x: codeOriginX, y: baselineY), in: context)
            codeOriginX += palette.charWidth
        }

        if !compiledLine.changeSpans.isEmpty {
            context.setFillColor(palette.changeHighlightBg)
            for (minX, maxX) in compiledLine.changeSpans {
                context.fill(CGRect(x: codeOriginX + minX, y: palette.highlightTop, width: maxX - minX, height: palette.highlightHeight))
            }
        }

        if !compiledLine.searchSpans.isEmpty {
            context.setFillColor(palette.searchHighlightBg)
            for (minX, maxX) in compiledLine.searchSpans {
                context.fill(CGRect(x: codeOriginX + minX, y: palette.highlightTop, width: maxX - minX, height: palette.highlightHeight))
            }
        }

        if let textSelectionRange {
            let startX = compiledLine.xOffset(forUTF16Index: textSelectionRange.lowerBound)
            let endX = textSelectionRange.isEmpty ? startX + 4 : compiledLine.xOffset(forUTF16Index: textSelectionRange.upperBound)
            if endX > startX {
                context.setFillColor(isTableFirstResponder ? palette.activeTextSelectionBg : palette.inactiveTextSelectionBg)
                context.fill(CGRect(x: codeOriginX + startX, y: 0, width: endX - startX, height: rowRect.height))
            }
        }

        drawCTLine(compiledLine.ctLine, at: CGPoint(x: codeOriginX, y: baselineY), in: context)

        if isFocused {
            context.setStrokeColor(palette.accentColor.cgColor)
            context.setLineWidth(1)
            context.stroke(rowRect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}

private final class SplitDiffCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("splitDiffCell")

    private var row: SplitDiffRow?
    private var leftCompiled: CompiledCodeLine?
    private var rightCompiled: CompiledCodeLine?
    private var palette: DiffRenderPalette?
    private var showsSelectionSlot = false
    private var leftSelected = false
    private var rightSelected = false
    private var leftFocused = false
    private var rightFocused = false
    private var leftOffset: CGFloat = 0
    private var rightOffset: CGFloat = 0
    private var leftTextSelectionRange: Range<Int>?
    private var rightTextSelectionRange: Range<Int>?
    private var isTableFirstResponder = false

    private var leftNumberLine: CTLine?
    private var rightNumberLine: CTLine?
    private var cachedLeftNumber: Int?
    private var cachedRightNumber: Int?
    private var cachedLeftKind: DiffLine.Kind?
    private var cachedRightKind: DiffLine.Kind?
    private var cachedAppearance: NSAppearance.Name?
    private var cachedFontSize: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseID
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(
        row: SplitDiffRow,
        leftCompiled: CompiledCodeLine?,
        rightCompiled: CompiledCodeLine?,
        palette: DiffRenderPalette,
        showsSelectionSlot: Bool,
        leftSelected: Bool,
        rightSelected: Bool,
        leftFocused: Bool,
        rightFocused: Bool,
        leftOffset: CGFloat,
        rightOffset: CGFloat,
        leftTextSelectionRange: Range<Int>?,
        rightTextSelectionRange: Range<Int>?,
        isTableFirstResponder: Bool
    ) {
        self.row = row
        self.leftCompiled = leftCompiled
        self.rightCompiled = rightCompiled
        self.palette = palette
        self.showsSelectionSlot = showsSelectionSlot
        self.leftSelected = leftSelected
        self.rightSelected = rightSelected
        self.leftFocused = leftFocused
        self.rightFocused = rightFocused
        self.leftOffset = leftOffset
        self.rightOffset = rightOffset
        self.leftTextSelectionRange = leftTextSelectionRange
        self.rightTextSelectionRange = rightTextSelectionRange
        self.isTableFirstResponder = isTableFirstResponder

        let appearanceChanged = cachedAppearance != palette.appearanceName || abs(cachedFontSize - palette.fontSize) > 0.01
        if appearanceChanged || cachedLeftNumber != row.left?.oldNumber || cachedLeftKind != row.left?.kind {
            cachedLeftNumber = row.left?.oldNumber
            cachedLeftKind = row.left?.kind
            if let left = row.left, let number = left.oldNumber {
                leftNumberLine = makeLineNumberCTLine(number, font: palette.monoRegular, color: gutterColor(for: left, palette: palette))
            } else {
                leftNumberLine = nil
            }
        }
        if appearanceChanged || cachedRightNumber != row.right?.newNumber || cachedRightKind != row.right?.kind {
            cachedRightNumber = row.right?.newNumber
            cachedRightKind = row.right?.kind
            if let right = row.right, let number = right.newNumber {
                rightNumberLine = makeLineNumberCTLine(number, font: palette.monoRegular, color: gutterColor(for: right, palette: palette))
            } else {
                rightNumberLine = nil
            }
        }
        cachedAppearance = palette.appearanceName
        cachedFontSize = palette.fontSize

        needsDisplay = true
    }

    func setHorizontalOffsets(left: CGFloat, right: CGFloat) {
        if abs(leftOffset - left) > 0.25 || abs(rightOffset - right) > 0.25 {
            leftOffset = left
            rightOffset = right
            needsDisplay = true
        }
    }

    private func gutterColor(for line: DiffLine, palette: DiffRenderPalette) -> NSColor {
        switch line.kind {
        case .addition: return palette.additionColor
        case .deletion: return palette.deletionColor
        default: return palette.tertiaryText
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let row,
              let palette else { return }

        let totalWidth = bounds.width
        let rowHeight = bounds.height
        let halfWidth = floor((totalWidth - 1) / 2)
        let rightOriginX = halfWidth + 1
        let rightWidth = max(0, totalWidth - rightOriginX)

        drawSide(
            in: CGRect(x: 0, y: 0, width: halfWidth, height: rowHeight),
            line: row.left,
            compiledLine: leftCompiled,
            numberLine: leftNumberLine,
            selected: leftSelected,
            focused: leftFocused,
            horizontalOffset: leftOffset,
            textSelectionRange: leftTextSelectionRange,
            palette: palette,
            context: context
        )

        context.setFillColor(palette.separatorColor.cgColor)
        context.fill(CGRect(x: halfWidth, y: 0, width: 1, height: rowHeight))

        drawSide(
            in: CGRect(x: rightOriginX, y: 0, width: rightWidth, height: rowHeight),
            line: row.right,
            compiledLine: rightCompiled,
            numberLine: rightNumberLine,
            selected: rightSelected,
            focused: rightFocused,
            horizontalOffset: rightOffset,
            textSelectionRange: rightTextSelectionRange,
            palette: palette,
            context: context
        )
    }

    private func drawSide(
        in sideRect: CGRect,
        line: DiffLine?,
        compiledLine: CompiledCodeLine?,
        numberLine: CTLine?,
        selected: Bool,
        focused: Bool,
        horizontalOffset: CGFloat,
        textSelectionRange: Range<Int>?,
        palette: DiffRenderPalette,
        context: CGContext
    ) {
        guard sideRect.width > 0 else { return }

        if let line {
            if selected {
                context.setFillColor(palette.splitSelectedBg)
                context.fill(sideRect)
            } else {
                switch line.kind {
                case .addition:
                    context.setFillColor(palette.splitAdditionBg)
                    context.fill(sideRect)
                case .deletion:
                    context.setFillColor(palette.splitDeletionBg)
                    context.fill(sideRect)
                case .hunk:
                    context.setFillColor(palette.splitHunkBg)
                    context.fill(sideRect)
                default:
                    break
                }
            }

            let isChange = line.kind == .addition || line.kind == .deletion
            if isChange {
                context.setFillColor((line.kind == .addition ? palette.additionColor : palette.deletionColor).cgColor)
                context.fill(CGRect(x: sideRect.minX, y: 0, width: 2, height: sideRect.height))
            }

            let slotWidth: CGFloat = showsSelectionSlot ? 25 : 0
            if showsSelectionSlot && isChange {
                let checkboxImage = selected ? palette.checkboxSelectedImage : palette.checkboxUnselectedImage
                if let checkboxImage {
                    let imageSize = checkboxImage.size
                    let imageRect = NSRect(
                        x: sideRect.minX + floor((25 - imageSize.width) / 2),
                        y: floor((sideRect.height - imageSize.height) / 2),
                        width: imageSize.width,
                        height: imageSize.height
                    )
                    checkboxImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }

            if let numberLine {
                let numberWidth = CGFloat(CTLineGetTypographicBounds(numberLine, nil, nil, nil))
                drawCTLine(numberLine, at: CGPoint(x: sideRect.minX + slotWidth + 42 - numberWidth, y: palette.baselineY), in: context)
            }

            let gutterWidth = slotWidth + 52
            let codeViewport = CGRect(x: sideRect.minX + gutterWidth, y: 0, width: max(0, sideRect.width - gutterWidth), height: sideRect.height)
            if codeViewport.width > 0, let compiledLine {
                context.saveGState()
                context.clip(to: codeViewport)
                let codeOriginX = codeViewport.minX - horizontalOffset

                if !compiledLine.changeSpans.isEmpty {
                    context.setFillColor(palette.changeHighlightBg)
                    for (minX, maxX) in compiledLine.changeSpans {
                        context.fill(CGRect(x: codeOriginX + minX, y: palette.highlightTop, width: maxX - minX, height: palette.highlightHeight))
                    }
                }

                if !compiledLine.searchSpans.isEmpty {
                    context.setFillColor(palette.searchHighlightBg)
                    for (minX, maxX) in compiledLine.searchSpans {
                        context.fill(CGRect(x: codeOriginX + minX, y: palette.highlightTop, width: maxX - minX, height: palette.highlightHeight))
                    }
                }

                if let textSelectionRange {
                    let startX = compiledLine.xOffset(forUTF16Index: textSelectionRange.lowerBound)
                    let endX = textSelectionRange.isEmpty ? startX + 4 : compiledLine.xOffset(forUTF16Index: textSelectionRange.upperBound)
                    if endX > startX {
                        context.setFillColor(isTableFirstResponder ? palette.activeTextSelectionBg : palette.inactiveTextSelectionBg)
                        context.fill(CGRect(x: codeOriginX + startX, y: 0, width: endX - startX, height: sideRect.height))
                    }
                }

                drawCTLine(compiledLine.ctLine, at: CGPoint(x: codeOriginX, y: palette.baselineY), in: context)
                context.restoreGState()
            }
        } else {
            context.setFillColor(palette.splitEmptyBg)
            context.fill(sideRect)
        }

        if focused {
            context.setStrokeColor(palette.accentColor.cgColor)
            context.setLineWidth(1)
            context.stroke(sideRect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}

private final class DiffSplitHeaderCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("diffSplitHeaderCell")

    private var leftTitle = ""
    private var rightTitle = ""
    private var palette: DiffRenderPalette?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseID
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(leftTitle: String, rightTitle: String, palette: DiffRenderPalette) {
        self.leftTitle = leftTitle
        self.rightTitle = rightTitle
        self.palette = palette
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let palette else { return }
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: palette.secondaryText,
            .kern: 0.5
        ]
        let ascent = font.ascender
        let descent = -font.descender
        let baselineY = ((bounds.height - (ascent + descent)) / 2 + ascent).rounded()
        let contentHalf = max(0, (bounds.width - 32) / 2)

        let leftLine = CTLineCreateWithAttributedString(NSAttributedString(string: leftTitle, attributes: attributes))
        drawCTLine(leftLine, at: CGPoint(x: 16, y: baselineY), in: context)

        let rightLine = CTLineCreateWithAttributedString(NSAttributedString(string: rightTitle, attributes: attributes))
        drawCTLine(rightLine, at: CGPoint(x: 16 + contentHalf, y: baselineY), in: context)
    }
}

private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

private final class DiffHunkHeaderCellView: NSTableCellView, HorizontallyPinnableCell, NSDraggingSource {
    static let reuseID = NSUserInterfaceItemIdentifier("diffHunkHeaderCell")

    private let pinnedContainer = FlippedContainerView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)
    private let primaryButton = NSButton(title: "", target: nil, action: nil)

    private var hunkID = 0
    private var palette: DiffRenderPalette?
    private var isSplit = false
    private var pinnedOriginX: CGFloat = 0
    private var pinnedWidth: CGFloat = 0
    private var supportsDrag = false
    private var dragStartPoint: NSPoint?
    private var onPrimary: ((Int) -> Void)?
    private var onSecondary: ((Int) -> Void)?
    private var onDragToken: ((Int) -> PicoDragToken?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseID

        headerLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.usesSingleLineMode = true
        headerLabel.maximumNumberOfLines = 1
        headerLabel.cell?.truncatesLastVisibleLine = true

        secondaryButton.bezelStyle = .push
        secondaryButton.controlSize = .mini
        secondaryButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        secondaryButton.hasDestructiveAction = true
        secondaryButton.target = self
        secondaryButton.action = #selector(triggerSecondary)

        primaryButton.bezelStyle = .push
        primaryButton.controlSize = .mini
        primaryButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        primaryButton.target = self
        primaryButton.action = #selector(triggerPrimary)

        pinnedContainer.addSubview(headerLabel)
        pinnedContainer.addSubview(secondaryButton)
        pinnedContainer.addSubview(primaryButton)
        addSubview(pinnedContainer)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(
        hunkID: Int,
        header: String,
        primaryTitle: String?,
        secondaryDestructiveTitle: String?,
        actionsEnabled: Bool,
        supportsDrag: Bool,
        palette: DiffRenderPalette,
        isSplit: Bool,
        onPrimary: @escaping (Int) -> Void,
        onSecondary: @escaping (Int) -> Void,
        onDragToken: @escaping (Int) -> PicoDragToken?
    ) {
        self.hunkID = hunkID
        self.palette = palette
        self.isSplit = isSplit
        self.supportsDrag = supportsDrag
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.onDragToken = onDragToken

        headerLabel.stringValue = header
        headerLabel.textColor = palette.hunkHeaderText

        if let primaryTitle {
            primaryButton.title = primaryTitle
            primaryButton.isHidden = false
            primaryButton.isEnabled = actionsEnabled
        } else {
            primaryButton.isHidden = true
        }

        if let secondaryDestructiveTitle {
            secondaryButton.title = secondaryDestructiveTitle
            secondaryButton.isHidden = false
            secondaryButton.isEnabled = actionsEnabled
        } else {
            secondaryButton.isHidden = true
        }

        layoutPinnedContent()
        needsDisplay = true
    }

    func setPinnedViewport(originX: CGFloat, width: CGFloat) {
        pinnedOriginX = originX
        pinnedWidth = width
        layoutPinnedContent()
    }

    override func layout() {
        super.layout()
        layoutPinnedContent()
    }

    private func layoutPinnedContent() {
        let effectiveWidth = isSplit ? bounds.width : (pinnedWidth > 1 ? pinnedWidth : bounds.width)
        let effectiveOriginX = isSplit ? 0 : pinnedOriginX
        let rowHeight = bounds.height > 0 ? bounds.height : 30
        pinnedContainer.frame = NSRect(x: effectiveOriginX, y: 0, width: effectiveWidth, height: rowHeight)

        var trailingX = effectiveWidth - 12
        if !primaryButton.isHidden {
            primaryButton.sizeToFit()
            let buttonWidth = ceil(primaryButton.frame.width)
            let buttonHeight = ceil(primaryButton.frame.height)
            trailingX -= buttonWidth
            primaryButton.frame = NSRect(x: trailingX, y: floor((rowHeight - buttonHeight) / 2), width: buttonWidth, height: buttonHeight)
            trailingX -= 8
        }

        if !secondaryButton.isHidden {
            secondaryButton.sizeToFit()
            let buttonWidth = ceil(secondaryButton.frame.width)
            let buttonHeight = ceil(secondaryButton.frame.height)
            trailingX -= buttonWidth
            secondaryButton.frame = NSRect(x: trailingX, y: floor((rowHeight - buttonHeight) / 2), width: buttonWidth, height: buttonHeight)
            trailingX -= 8
        }

        let labelHeight: CGFloat = 14
        headerLabel.frame = NSRect(
            x: 12,
            y: floor((rowHeight - labelHeight) / 2),
            width: max(0, trailingX - 12),
            height: labelHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let palette else { return }
        context.setFillColor(palette.hunkHeaderBg)
        context.fill(bounds)
        context.setFillColor(palette.hunkHeaderDivider)
        context.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1))
    }

    @objc private func triggerPrimary() {
        onPrimary?(hunkID)
    }

    @objc private func triggerSecondary() {
        onSecondary?(hunkID)
    }

    override func mouseDown(with event: NSEvent) {
        if supportsDrag {
            dragStartPoint = convert(event.locationInWindow, from: nil)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard supportsDrag, let start = dragStartPoint else {
            super.mouseDragged(with: event)
            return
        }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) >= 4 else { return }
        dragStartPoint = nil
        guard let token = onDragToken?(hunkID), let data = try? JSONEncoder().encode(token) else { return }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(UTType.picoDrag.identifier))
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(NSRect(x: current.x - 40, y: current.y - 10, width: 120, height: 20), contents: nil)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
        super.mouseUp(with: event)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}

private final class StashDragLabel: NSTextField, NSDraggingSource {
    var onDragToken: (() -> PicoDragToken?)?
    private var dragStartPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) >= 3 else { return }
        dragStartPoint = nil
        guard let token = onDragToken?(), let data = try? JSONEncoder().encode(token) else { return }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(UTType.picoDrag.identifier))
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: nil)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}

private final class DiffStashSelectionBarCellView: NSTableCellView, HorizontallyPinnableCell {
    static let reuseID = NSUserInterfaceItemIdentifier("diffStashSelectionBarCell")

    private let pinnedContainer = FlippedContainerView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: String(localized: "Clear"), target: nil, action: nil)
    private let applyButton = NSButton(title: String(localized: "Apply Selected Lines…"), target: nil, action: nil)
    private let dragLabel = StashDragLabel(labelWithString: String(localized: "Drag Selected Lines"))

    private var palette: DiffRenderPalette?
    private var isSplit = false
    private var pinnedOriginX: CGFloat = 0
    private var pinnedWidth: CGFloat = 0
    private var onClear: (() -> Void)?
    private var onApply: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseID

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.lineBreakMode = .byTruncatingTail

        clearButton.bezelStyle = .push
        clearButton.controlSize = .mini
        clearButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        clearButton.target = self
        clearButton.action = #selector(triggerClear)

        applyButton.bezelStyle = .push
        applyButton.controlSize = .mini
        applyButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        applyButton.target = self
        applyButton.action = #selector(triggerApply)

        dragLabel.font = .systemFont(ofSize: 10)
        dragLabel.toolTip = String(localized: "Drag to Working Copy to apply selected lines")

        pinnedContainer.addSubview(statusLabel)
        pinnedContainer.addSubview(clearButton)
        pinnedContainer.addSubview(applyButton)
        pinnedContainer.addSubview(dragLabel)
        addSubview(pinnedContainer)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(
        selectedCount: Int,
        isDisabled: Bool,
        palette: DiffRenderPalette,
        isSplit: Bool,
        onClear: @escaping () -> Void,
        onApply: @escaping () -> Void,
        onDragToken: @escaping () -> PicoDragToken?
    ) {
        self.palette = palette
        self.isSplit = isSplit
        self.onClear = onClear
        self.onApply = onApply
        dragLabel.onDragToken = onDragToken

        statusLabel.textColor = palette.secondaryText
        dragLabel.textColor = palette.primaryText
        statusLabel.stringValue = selectedCount == 0
            ? String(localized: "Click the gutter to pick lines")
            : String(localized: "\(selectedCount) lines selected")

        let showsSelectionControls = selectedCount > 0
        clearButton.isHidden = !showsSelectionControls
        applyButton.isHidden = !showsSelectionControls
        dragLabel.isHidden = !showsSelectionControls
        clearButton.isEnabled = !isDisabled
        applyButton.isEnabled = !isDisabled

        layoutPinnedContent()
        needsDisplay = true
    }

    func setPinnedViewport(originX: CGFloat, width: CGFloat) {
        pinnedOriginX = originX
        pinnedWidth = width
        layoutPinnedContent()
    }

    override func layout() {
        super.layout()
        layoutPinnedContent()
    }

    private func layoutPinnedContent() {
        let effectiveWidth = isSplit ? bounds.width : (pinnedWidth > 1 ? pinnedWidth : bounds.width)
        let effectiveOriginX = isSplit ? 0 : pinnedOriginX
        let rowHeight = bounds.height > 0 ? bounds.height : 30
        pinnedContainer.frame = NSRect(x: effectiveOriginX, y: 0, width: effectiveWidth, height: rowHeight)

        var trailingX = effectiveWidth - 8
        if !dragLabel.isHidden {
            dragLabel.sizeToFit()
            let labelWidth = ceil(dragLabel.frame.width)
            let labelHeight = ceil(dragLabel.frame.height)
            trailingX -= labelWidth
            dragLabel.frame = NSRect(x: trailingX, y: floor((rowHeight - labelHeight) / 2), width: labelWidth, height: labelHeight)
            trailingX -= 8
        }
        if !applyButton.isHidden {
            applyButton.sizeToFit()
            let buttonWidth = ceil(applyButton.frame.width)
            let buttonHeight = ceil(applyButton.frame.height)
            trailingX -= buttonWidth
            applyButton.frame = NSRect(x: trailingX, y: floor((rowHeight - buttonHeight) / 2), width: buttonWidth, height: buttonHeight)
            trailingX -= 6
        }
        if !clearButton.isHidden {
            clearButton.sizeToFit()
            let buttonWidth = ceil(clearButton.frame.width)
            let buttonHeight = ceil(clearButton.frame.height)
            trailingX -= buttonWidth
            clearButton.frame = NSRect(x: trailingX, y: floor((rowHeight - buttonHeight) / 2), width: buttonWidth, height: buttonHeight)
            trailingX -= 8
        }

        let statusHeight: CGFloat = 14
        statusLabel.frame = NSRect(
            x: 8,
            y: floor((rowHeight - statusHeight) / 2),
            width: max(0, trailingX - 8),
            height: statusHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let palette else { return }
        context.setFillColor(palette.stashBarBg)
        context.fill(bounds)
    }

    @objc private func triggerClear() {
        onClear?()
    }

    @objc private func triggerApply() {
        onApply?()
    }
}

private final class DiffTruncationNoticeCellView: NSTableCellView, HorizontallyPinnableCell {
    static let reuseID = NSUserInterfaceItemIdentifier("diffTruncationNoticeCell")

    private let pinnedContainer = FlippedContainerView()
    private let messageLabel = NSTextField(labelWithString: "")
    private var isSplit = false
    private var pinnedOriginX: CGFloat = 0
    private var pinnedWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseID
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.lineBreakMode = .byTruncatingTail
        pinnedContainer.addSubview(messageLabel)
        addSubview(pinnedContainer)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(message: String, palette: DiffRenderPalette, isSplit: Bool) {
        self.isSplit = isSplit
        messageLabel.stringValue = message
        messageLabel.textColor = palette.secondaryText
        layoutPinnedContent()
    }

    func setPinnedViewport(originX: CGFloat, width: CGFloat) {
        pinnedOriginX = originX
        pinnedWidth = width
        layoutPinnedContent()
    }

    override func layout() {
        super.layout()
        layoutPinnedContent()
    }

    private func layoutPinnedContent() {
        let effectiveWidth = isSplit ? bounds.width : (pinnedWidth > 1 ? pinnedWidth : bounds.width)
        let effectiveOriginX = isSplit ? 0 : pinnedOriginX
        let rowHeight = bounds.height > 0 ? bounds.height : 36
        pinnedContainer.frame = NSRect(x: effectiveOriginX, y: 0, width: effectiveWidth, height: rowHeight)
        messageLabel.frame = NSRect(x: 12, y: floor((rowHeight - 15) / 2), width: max(0, effectiveWidth - 24), height: 15)
    }
}

final class DiffTableView: NSTableView {
    weak var interactionDelegate: DiffTableInteractionDelegate?
    private var dragAnchorSelection: DiffTextSelection?
    private var dragClickCount = 1
    private var hoverTrackingArea: NSTrackingArea?
    private var pendingCopyLineText: String?

    var isActiveFirstResponder: Bool {
        window?.firstResponder === self
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            interactionDelegate?.handleFirstResponderChanged()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            interactionDelegate?.handleFirstResponderChanged()
        }
        return resigned
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        interactionDelegate?.handleEffectiveAppearanceChanged()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateHoverFeedback(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverFeedback(for: event)
    }

    private func updateHoverFeedback(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let target = interactionDelegate?.interactionTarget(at: point) else {
            NSCursor.arrow.set()
            toolTip = nil
            return
        }
        switch target {
        case .selectableGutter:
            NSCursor.pointingHand.set()
            toolTip = String(localized: "Select line; Shift-click selects a range")
        case .code:
            NSCursor.iBeam.set()
            toolTip = nil
        case .none:
            NSCursor.arrow.set()
            toolTip = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let delegate = interactionDelegate else {
            super.mouseDown(with: event)
            return
        }

        switch delegate.interactionTarget(at: point) {
        case .selectableGutter(let hunkID, let line):
            dragAnchorSelection = nil
            delegate.toggleSelectableLine(hunkID: hunkID, line: line)
            return

        case .code:
            window?.makeFirstResponder(self)
            guard let position = delegate.textPosition(at: point, lockedColumn: nil) else {
                delegate.setTextSelection(nil)
                dragAnchorSelection = nil
                return
            }
            dragClickCount = event.clickCount
            if event.clickCount >= 3 {
                let selection = delegate.lineSelection(at: position)
                dragAnchorSelection = selection
                delegate.setTextSelection(selection)
            } else if event.clickCount == 2 {
                let selection = delegate.wordSelection(at: position)
                dragAnchorSelection = selection
                delegate.setTextSelection(selection)
            } else if event.modifierFlags.contains(.shift),
                      let existing = delegate.currentTextSelection(),
                      existing.column == position.column {
                let extended = DiffTextSelection(anchor: existing.anchor, head: position)
                dragAnchorSelection = DiffTextSelection(anchor: existing.anchor, head: existing.anchor)
                delegate.setTextSelection(extended)
            } else {
                let initial = DiffTextSelection(anchor: position, head: position)
                dragAnchorSelection = initial
                delegate.setTextSelection(initial)
            }

        case .none:
            dragAnchorSelection = nil
            delegate.setTextSelection(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let delegate = interactionDelegate, let anchorSelection = dragAnchorSelection else {
            super.mouseDragged(with: event)
            return
        }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let currentPosition = delegate.textPosition(at: point, lockedColumn: anchorSelection.column) else { return }
        let updated = delegate.extendSelection(anchorSelection: anchorSelection, to: currentPosition, clickCount: dragClickCount)
        delegate.setTextSelection(updated)
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchorSelection = nil
        super.mouseUp(with: event)
    }

    @objc func copy(_ sender: Any?) {
        guard let text = interactionDelegate?.selectedTextForCopy(), !text.isEmpty else { return }
        Pico.copy(text)
    }

    @objc private func copyClickedLine(_ sender: Any?) {
        guard let pendingCopyLineText else { return }
        Pico.copy(pendingCopyLineText)
    }

    override func selectAll(_ sender: Any?) {
        interactionDelegate?.selectAllText()
    }

    override func cancelOperation(_ sender: Any?) {
        if interactionDelegate?.hasActiveTextSelection == true {
            interactionDelegate?.setTextSelection(nil)
        } else {
            super.cancelOperation(sender)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return interactionDelegate?.hasActiveTextSelection == true
        }
        if item.action == #selector(copyClickedLine(_:)) {
            return pendingCopyLineText != nil
        }
        if item.action == #selector(selectAll(_:)) {
            return interactionDelegate?.hasSelectableTextRows == true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedLine = interactionDelegate?.fullSourceLine(at: point)
        let hasSelection = interactionDelegate?.hasActiveTextSelection == true
        guard hasSelection || clickedLine != nil else { return nil }

        pendingCopyLineText = clickedLine
        let menu = NSMenu()
        if hasSelection {
            let copyItem = NSMenuItem(title: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "c")
            copyItem.target = self
            menu.addItem(copyItem)
        }
        if clickedLine != nil {
            let copyLineItem = NSMenuItem(title: String(localized: "Copy Line"), action: #selector(copyClickedLine(_:)), keyEquivalent: "")
            copyLineItem.target = self
            menu.addItem(copyLineItem)
        }
        return menu
    }
}

private final class SplitHorizontalScrollerHost: NSScrollView {
    private let spacer = NSView()
    private var syncing = false
    private var maxOffset: CGFloat = 0
    nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
    var onOffsetChanged: ((CGFloat) -> Void)?
    var onForwardScrollWheel: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        documentView = spacer
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.syncing else { return }
                let offset = min(self.maxOffset, max(0, self.contentView.bounds.origin.x))
                self.onOffsetChanged?(offset)
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    func teardown() {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
    }

    func sync(offset: CGFloat, maxOffset: CGFloat, viewportWidth: CGFloat, flash: Bool) {
        self.maxOffset = maxOffset
        let contentWidth = max(1, viewportWidth + maxOffset)
        syncing = true
        if abs(spacer.frame.width - contentWidth) > 0.5 || abs(spacer.frame.height - bounds.height) > 0.5 {
            spacer.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(1, bounds.height))
        }
        let targetX = min(maxOffset, max(0, offset))
        if abs(contentView.bounds.origin.x - targetX) > 0.25 {
            contentView.scroll(to: NSPoint(x: targetX, y: 0))
            reflectScrolledClipView(contentView)
        }
        syncing = false
        if flash {
            flashScrollers()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        onForwardScrollWheel?(event)
    }
}

final class DiffScrollView: NSScrollView {
    private let leftSplitScroller = SplitHorizontalScrollerHost()
    private let rightSplitScroller = SplitHorizontalScrollerHost()

    private var isSplitMode = false
    private var splitHalfWidth: CGFloat = 0
    private var splitGutterWidth: CGFloat = 0
    private var maxLeftOffset: CGFloat = 0
    private var maxRightOffset: CGFloat = 0
    private var leftOffset: CGFloat = 0
    private var rightOffset: CGFloat = 0
    private var lastReportedViewportWidth: CGFloat = 0

    var onSplitOffsetsChanged: ((CGFloat, CGFloat) -> Void)?
    var onViewportWidthChanged: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        leftSplitScroller.isHidden = true
        rightSplitScroller.isHidden = true
        leftSplitScroller.onOffsetChanged = { [weak self] offset in
            self?.setSplitOffset(offset, isRight: false, syncScroller: false, flash: false)
        }
        rightSplitScroller.onOffsetChanged = { [weak self] offset in
            self?.setSplitOffset(offset, isRight: true, syncScroller: false, flash: false)
        }
        leftSplitScroller.onForwardScrollWheel = { [weak self] event in
            self?.scrollWheel(with: event)
        }
        rightSplitScroller.onForwardScrollWheel = { [weak self] event in
            self?.scrollWheel(with: event)
        }
        addSubview(leftSplitScroller)
        addSubview(rightSplitScroller)
    }

    required init?(coder: NSCoder) { nil }

    func teardown() {
        leftSplitScroller.teardown()
        rightSplitScroller.teardown()
    }

    func resetSplitOffsets() {
        leftOffset = 0
        rightOffset = 0
        syncSplitScrollers(flashLeft: false, flashRight: false)
    }

    func updateSplitHorizontalMetrics(
        isSplit: Bool,
        halfWidth: CGFloat,
        gutterWidth: CGFloat,
        maxLeftOffset: CGFloat,
        maxRightOffset: CGFloat
    ) {
        self.isSplitMode = isSplit
        self.splitHalfWidth = halfWidth
        self.splitGutterWidth = gutterWidth
        self.maxLeftOffset = maxLeftOffset
        self.maxRightOffset = maxRightOffset

        let clampedLeft = min(maxLeftOffset, max(0, leftOffset))
        let clampedRight = min(maxRightOffset, max(0, rightOffset))
        let offsetsChanged = abs(clampedLeft - leftOffset) > 0.25 || abs(clampedRight - rightOffset) > 0.25
        leftOffset = clampedLeft
        rightOffset = clampedRight

        layoutSplitScrollers()
        syncSplitScrollers(flashLeft: false, flashRight: false)
        if offsetsChanged {
            onSplitOffsetsChanged?(leftOffset, rightOffset)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if isSplitMode {
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            if deltaX != 0 && abs(deltaX) > abs(deltaY) {
                let local = convert(event.locationInWindow, from: nil)
                let isRight = local.x >= contentView.frame.midX
                let scaledDelta = event.hasPreciseScrollingDeltas ? deltaX : deltaX * 24
                if scrollSplitHorizontally(deltaX: scaledDelta, isRight: isRight) {
                    return
                }
            }
        }
        super.scrollWheel(with: event)
    }

    private func scrollSplitHorizontally(deltaX: CGFloat, isRight: Bool) -> Bool {
        let limit = isRight ? maxRightOffset : maxLeftOffset
        guard limit > 0 else { return false }
        let current = isRight ? rightOffset : leftOffset
        let next = min(limit, max(0, current - deltaX))
        guard abs(next - current) > 0.01 else { return false }
        setSplitOffset(next, isRight: isRight, syncScroller: true, flash: true)
        return true
    }

    private func setSplitOffset(_ offset: CGFloat, isRight: Bool, syncScroller: Bool, flash: Bool) {
        let limit = isRight ? maxRightOffset : maxLeftOffset
        let clamped = min(limit, max(0, offset))
        if isRight {
            guard abs(rightOffset - clamped) > 0.01 else { return }
            rightOffset = clamped
            if syncScroller {
                syncSplitScrollers(flashLeft: false, flashRight: flash)
            }
        } else {
            guard abs(leftOffset - clamped) > 0.01 else { return }
            leftOffset = clamped
            if syncScroller {
                syncSplitScrollers(flashLeft: flash, flashRight: false)
            }
        }
        onSplitOffsetsChanged?(leftOffset, rightOffset)
    }

    override func tile() {
        super.tile()
        let viewport = contentView.frame
        if abs(viewport.width - lastReportedViewportWidth) > 0.25 {
            lastReportedViewportWidth = viewport.width
            onViewportWidthChanged?(viewport.width)
        }
        layoutSplitScrollers()
        syncSplitScrollers(flashLeft: false, flashRight: false)
    }

    private func layoutSplitScrollers() {
        let viewport = contentView.frame
        let barHeight = max(12, NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay))
        let bottomOffset = contentInsets.bottom
        let barY = isFlipped ? viewport.maxY - bottomOffset - barHeight : viewport.minY + bottomOffset
        let leftCodeWidth = max(0, splitHalfWidth - splitGutterWidth)
        let rightOriginX = splitHalfWidth + 1
        let rightWidth = max(0, viewport.width - rightOriginX)
        let rightCodeWidth = max(0, rightWidth - splitGutterWidth)

        let showLeft = isSplitMode && maxLeftOffset > 0 && leftCodeWidth > 8
        let showRight = isSplitMode && maxRightOffset > 0 && rightCodeWidth > 8

        leftSplitScroller.isHidden = !showLeft
        rightSplitScroller.isHidden = !showRight

        if showLeft {
            leftSplitScroller.frame = NSRect(x: viewport.minX + splitGutterWidth, y: barY, width: leftCodeWidth, height: barHeight)
        }
        if showRight {
            rightSplitScroller.frame = NSRect(x: viewport.minX + rightOriginX + splitGutterWidth, y: barY, width: rightCodeWidth, height: barHeight)
        }
    }

    private func syncSplitScrollers(flashLeft: Bool, flashRight: Bool) {
        guard isSplitMode else { return }
        if !leftSplitScroller.isHidden {
            leftSplitScroller.sync(offset: leftOffset, maxOffset: maxLeftOffset, viewportWidth: leftSplitScroller.bounds.width, flash: flashLeft)
        }
        if !rightSplitScroller.isHidden {
            rightSplitScroller.sync(offset: rightOffset, maxOffset: maxRightOffset, viewportWidth: rightSplitScroller.bounds.width, flash: flashRight)
        }
    }
}
