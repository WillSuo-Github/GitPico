import AppKit
import GitCore
import SwiftUI

struct ChunkDiffView: View {
    let prepared: PreparedPatch?
    var isLoading = false
    var chunkAction: ((Int) -> Void)? = nil
    var lineAction: ((Set<PatchLineID>) -> Void)? = nil
    var unstaging = false
    var actionTitle = String(localized: "Stage Chunk")
    var lineActionTitle: LocalizedStringResource { unstaging ? "Unstage Lines" : "Stage Lines" }
    var leftTitle = String(localized: "Original")
    var rightTitle = String(localized: "Changed")
    var disabled = false
    var discardChunk: ((Int) -> Void)? = nil
    var discardLines: ((Set<PatchLineID>) -> Void)? = nil
    var exportLines: ((Set<PatchLineID>) -> Void)? = nil
    var backgroundStyle = AnyShapeStyle(Color(nsColor: .textBackgroundColor))
    @State private var preferences = AppPreferences.shared
    @State private var selectedLines = PatchLineSelection()
    @State private var findQuery = ""
    @State private var focusedLine: String?
    @State private var findReveal = UUID()
    @State private var findMatches: [String] = []
    @State private var matchedLineIDs: Set<String> = []
    @State private var unifiedScroll = UnifiedHorizontalScrollState()
    @State private var splitScroll = SplitHorizontalScrollState()

    private struct FindKey: Equatable {
        let patchID: UUID?
        let query: String
    }

    var body: some View {
        Group {
        if isLoading && prepared == nil { ProgressView("Loading changes…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        else if prepared?.source.isEmpty ?? true { EmptyPane(title: String(localized: "No textual changes"), subtitle: String(localized: "Select the other diff version if this file is partially staged."), icon: "doc.text.magnifyingglass") }
        else if let prepared {
            let patch = prepared.patch
            let canSelectAny = lineAction != nil && patch.supportsChunkStaging
            PinnedScrollPane { insets in
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        Group {
                            if preferences.splitDiff {
                                let layout = DiffLayoutMetrics.splitLayout(
                                    leftColumns: prepared.maxSplitLeftColumns,
                                    rightColumns: prepared.maxSplitRightColumns,
                                    fontSize: preferences.diffFontSize,
                                    selectable: canSelectAny,
                                    totalWidth: geometry.size.width
                                )
                                let rowHeight = DiffLayoutMetrics.splitRowHeight(fontSize: preferences.diffFontSize)
                                ScrollView(.vertical) {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        HStack(spacing: 0) {
                                            Text(leftTitle).frame(maxWidth: .infinity, alignment: .leading)
                                            Text(rightTitle).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                                        .foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 24)
                                        .environment(\.layoutDirection, .leftToRight)
                                        if patch.hunks.isEmpty {
                                            Text(DiffLayoutMetrics.rawFallbackPreview(prepared.source))
                                                .font(.system(size: preferences.diffFontSize, design: .monospaced))
                                                .textSelection(.enabled).padding(12)
                                        }
                                        ForEach(prepared.splitItems) { item in
                                            switch item {
                                            case .hunkHeader(let preview):
                                                hunkHeader(preview, supportsChunkStaging: patch.supportsChunkStaging, includesChrome: true)
                                                    .frame(width: geometry.size.width)
                                            case .row(let hunkID, let row, let isSelectableHunk):
                                                let canSelect = lineAction != nil && isSelectableHunk
                                                let hunkCode = prepared.code[hunkID]
                                                let leftKey = row.left.map { "\(hunkID):\($0.id)" }
                                                let rightKey = row.right.map { "\(hunkID):\($0.id)" }
                                                SplitDiffRowView(
                                                    row: row,
                                                    fontSize: preferences.diffFontSize,
                                                    halfWidth: layout.halfWidth,
                                                    rowHeight: rowHeight,
                                                    leftCode: row.left.flatMap { hunkCode?[$0.id] },
                                                    rightCode: row.right.flatMap { hunkCode?[$0.id] },
                                                    leftSelected: row.left.map { selectedLines.ids.contains(PatchLineID(hunk: hunkID, line: $0.id)) } ?? false,
                                                    rightSelected: row.right.map { selectedLines.ids.contains(PatchLineID(hunk: hunkID, line: $0.id)) } ?? false,
                                                    leftFocused: leftKey != nil && focusedLine == leftKey,
                                                    rightFocused: rightKey != nil && focusedLine == rightKey,
                                                    leftQuery: leftKey.map { matchedLineIDs.contains($0) ? findQuery : "" } ?? "",
                                                    rightQuery: rightKey.map { matchedLineIDs.contains($0) ? findQuery : "" } ?? "",
                                                    showsSelectionSlot: canSelect,
                                                    scrollState: splitScroll,
                                                    select: canSelect ? { toggle($0, hunkID: hunkID, prepared: prepared) } : nil
                                                ).equatable()
                                            case .truncationNotice:
                                                truncationNotice
                                            }
                                        }
                                    }
                                    .frame(minWidth: geometry.size.width, minHeight: max(0, geometry.size.height - insets.top - insets.bottom), alignment: .topLeading)
                                }
                                .defaultScrollAnchor(.topLeading).pinnedScrollInsets(insets)
                                .background(SplitHorizontalWheelBridge(scrollState: splitScroll, maxLeftOffset: layout.maxLeftOffset, maxRightOffset: layout.maxRightOffset))
                                .overlay(alignment: .bottom) {
                                    SplitHorizontalScrollbarOverlay(
                                        scrollState: splitScroll,
                                        halfWidth: layout.halfWidth,
                                        gutterWidth: layout.gutterWidth,
                                        maxLeftOffset: layout.maxLeftOffset,
                                        maxRightOffset: layout.maxRightOffset,
                                        bottomInset: insets.bottom
                                    )
                                }
                            } else {
                                let contentWidth = DiffLayoutMetrics.unifiedContentWidth(
                                    columns: prepared.maxUnifiedColumns,
                                    fontSize: preferences.diffFontSize,
                                    selectable: canSelectAny,
                                    minimumWidth: geometry.size.width
                                )
                                ScrollView([.horizontal, .vertical]) {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        if patch.hunks.isEmpty {
                                            Text(DiffLayoutMetrics.rawFallbackPreview(prepared.source))
                                                .font(.system(size: preferences.diffFontSize, design: .monospaced))
                                                .textSelection(.enabled).padding(12)
                                        }
                                        ForEach(prepared.unifiedItems) { item in
                                            switch item {
                                            case .hunkHeader(let preview):
                                                PinnedHorizontalBar(scrollState: unifiedScroll, viewportWidth: geometry.size.width) {
                                                    hunkHeader(preview, supportsChunkStaging: patch.supportsChunkStaging, includesChrome: false)
                                                }
                                                .frame(minWidth: contentWidth, alignment: .leading)
                                                .background(Color.accentColor.opacity(0.06))
                                                .overlay(alignment: .top) { Divider().opacity(0.6) }
                                            case .line(let hunkID, let line, let isSelectableHunk):
                                                let canSelect = lineAction != nil && isSelectableHunk
                                                let lineKey = "\(hunkID):\(line.id)"
                                                UnifiedDiffLineRow(
                                                    line: line,
                                                    fontSize: preferences.diffFontSize,
                                                    code: prepared.code[hunkID]?[line.id],
                                                    query: matchedLineIDs.contains(lineKey) ? findQuery : "",
                                                    selected: selectedLines.ids.contains(PatchLineID(hunk: hunkID, line: line.id)),
                                                    focused: focusedLine == lineKey,
                                                    showsSelectionSlot: canSelect,
                                                    minimumWidth: contentWidth,
                                                    select: canSelect ? { toggle(line, hunkID: hunkID, prepared: prepared) } : nil
                                                ).equatable()
                                            case .truncationNotice:
                                                PinnedHorizontalBar(scrollState: unifiedScroll, viewportWidth: geometry.size.width) {
                                                    truncationNotice
                                                }
                                            }
                                        }
                                    }
                                    .frame(minWidth: contentWidth, minHeight: max(0, geometry.size.height - insets.top - insets.bottom), alignment: .topLeading)
                                }
                                .defaultScrollAnchor(.topLeading).pinnedScrollInsets(insets)
                                .onScrollGeometryChange(for: CGFloat.self, of: { max(0, $0.contentOffset.x) }) { _, newValue in
                                    if abs(unifiedScroll.offsetX - newValue) > 0.25 { unifiedScroll.offsetX = newValue }
                                }
                            }
                        }
                        .onChange(of: findReveal) {
                            guard let focusedLine else { return }
                            let target = preferences.splitDiff ? (prepared.splitScrollTargets[focusedLine] ?? focusedLine) : focusedLine
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }.background(backgroundStyle)
            } top: {
                DiffFindBar(query: $findQuery, matches: findMatches, selection: $focusedLine) { findReveal = UUID() }
                HStack(spacing: 10) {
                    DiffStat(additions: patch.additions, deletions: patch.deletions)
                    Text("\(patch.hunks.count) chunks").foregroundStyle(.secondary)
                    Spacer()
                    if lineAction != nil, patch.supportsChunkStaging {
                        if selectedLines.ids.isEmpty {
                            Label("Click the gutter to pick lines", systemImage: "hand.point.up.left").foregroundStyle(.tertiary)
                        } else {
                            Text("\(selectedLines.ids.count) lines selected").foregroundStyle(.secondary)
                            Menu {
                                Button("Clear Selection") { selectedLines.clear() }
                                if let exportLines { Button("Save Lines as Patch…") { exportLines(selectedLines.ids) } }
                            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            if let discardLines { Button("Discard Lines…", role: .destructive) { discardLines(selectedLines.ids) } }
                            Button(lineActionTitle) { lineAction?(selectedLines.ids) }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.return, modifiers: [.command, .shift])
                        }
                    }
                }.font(.system(size: 11)).controlSize(.small).padding(.horizontal, 14).frame(height: 34).disabled(disabled)
            }
        }
        }
        .disabled(disabled || isLoading)
        .onChange(of: prepared?.id) {
            selectedLines.clear()
            unifiedScroll.offsetX = 0
            splitScroll.reset()
        }
        .onChange(of: leftTitle) { selectedLines.clear() }
        .task(id: FindKey(patchID: prepared?.id, query: findQuery)) {
            guard let prepared, !findQuery.isEmpty else {
                findMatches = []
                matchedLineIDs = []
                return
            }
            let query = findQuery
            let matches = await Task.detached(priority: .userInitiated) { prepared.matchingLineIDs(query: query) }.value
            guard !Task.isCancelled else { return }
            findMatches = matches
            matchedLineIDs = Set(matches)
        }
    }

    private func hunkHeader(_ preview: PatchHunkPreview, supportsChunkStaging: Bool, includesChrome: Bool) -> some View {
        let hunk = preview.hunk
        return HStack {
            Text(hunk.header).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.accentColor.opacity(0.85)).lineLimit(1)
            Spacer()
            if let discardChunk, supportsChunkStaging {
                Button("Discard Chunk…", role: .destructive) { discardChunk(hunk.id) }.controlSize(.mini).disabled(disabled || preview.isTruncated)
            }
            if let chunkAction, supportsChunkStaging {
                Button(actionTitle) { chunkAction(hunk.id) }.controlSize(.mini).disabled(disabled || preview.isTruncated)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background { if includesChrome { Color.accentColor.opacity(0.06) } }
        .overlay(alignment: .top) { if includesChrome { Divider().opacity(0.6) } }
    }

    private var truncationNotice: some View {
        Text("Preview limited to 8,000 lines. Review the complete diff in an external tool.")
            .font(.caption).foregroundStyle(.secondary).padding(12)
    }

    func toggle(_ line: DiffLine, hunkID: Int, prepared: PreparedPatch) {
        guard !disabled, !isLoading else { return }
        selectedLines.toggle(PatchLineID(hunk: hunkID, line: line.id), extending: NSEvent.modifierFlags.contains(.shift), order: prepared.selectableOrder)
    }

}

extension PatchDocument {
    var summary: String {
        [String(localized: "\(hunks.count) chunks"), String(localized: "\(additions) insertions"), String(localized: "\(deletions) deletions")].formatted(.list(type: .and, width: .narrow))
    }
}
