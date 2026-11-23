import AppKit
import GitCore
import SwiftUI

struct StashFileDisclosure: View {
    let store: RepositoryStore
    let repository: GitRepository
    let stash: Stash
    let file: StashFile
    let statistics: FileStatistics?
    @Binding var expanded: Bool
    @Binding var selected: Bool
    @State private var lineSelection: Set<PatchLineID> = []
    @State private var anchor: PatchLineID?
    @State private var diff: String?
    @State private var prepared: PreparedPatch?
    @State private var findQuery = ""
    @State private var focusedLine: String?
    @State private var findReveal = UUID()
    @State private var findMatches: [String] = []
    @State private var matchedLineIDs: Set<String> = []
    @State private var error: String?
    @State private var preferences = AppPreferences.shared
    @State private var unifiedScroll = UnifiedHorizontalScrollState()
    @State private var splitScroll = SplitHorizontalScrollState()

    private struct FindKey: Equatable {
        let patchID: UUID?
        let query: String
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            DisclosureGroup(isExpanded: $expanded) {
                if statistics?.isBinary == true {
                    Text("Binary file — apply the whole file to restore its exact contents.").font(.caption).foregroundStyle(.secondary).padding(16)
                } else if let prepared, let diff {
                    let document = prepared.patch
                    let previews = prepared.previews
                    PinnedScrollPane { insets in
                        GeometryReader { geometry in
                        ScrollViewReader { proxy in
                        Group {
                            if preferences.splitDiff {
                                let layout = DiffLayoutMetrics.splitLayout(
                                    leftColumns: prepared.maxSplitLeftColumns,
                                    rightColumns: prepared.maxSplitRightColumns,
                                    fontSize: preferences.diffFontSize,
                                    selectable: document.supportsChunkStaging,
                                    totalWidth: geometry.size.width
                                )
                                let rowHeight = DiffLayoutMetrics.splitRowHeight(fontSize: preferences.diffFontSize)
                                ScrollView(.vertical) {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        if document.hunks.isEmpty {
                                            Text(DiffLayoutMetrics.rawFallbackPreview(diff))
                                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        if document.supportsChunkStaging {
                                            selectionBar(diff: diff, includesBackground: true)
                                        }
                                        ForEach(prepared.splitItems) { item in
                                            switch item {
                                            case .hunkHeader(let preview):
                                                    stashHunkHeader(preview, diff: diff, supportsChunkStaging: document.supportsChunkStaging, includesBackground: true)
                                                    .frame(width: geometry.size.width)
                                            case .row(let hunkID, let row, let isSelectableHunk):
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
                                                    leftSelected: row.left.map { lineSelection.contains(PatchLineID(hunk: hunkID, line: $0.id)) } ?? false,
                                                    rightSelected: row.right.map { lineSelection.contains(PatchLineID(hunk: hunkID, line: $0.id)) } ?? false,
                                                    leftFocused: leftKey != nil && focusedLine == leftKey,
                                                    rightFocused: rightKey != nil && focusedLine == rightKey,
                                                    leftQuery: leftKey.map { matchedLineIDs.contains($0) ? findQuery : "" } ?? "",
                                                    rightQuery: rightKey.map { matchedLineIDs.contains($0) ? findQuery : "" } ?? "",
                                                    showsSelectionSlot: isSelectableHunk,
                                                    scrollState: splitScroll,
                                                    select: isSelectableHunk ? { toggle($0, hunkID: hunkID, prepared: prepared) } : nil
                                                ).equatable()
                                            case .truncationNotice:
                                                Text("Preview limited to 8,000 lines.").font(.caption).foregroundStyle(.secondary).padding(12)
                                            }
                                        }
                                    }
                                    .frame(minWidth: geometry.size.width, minHeight: max(0, geometry.size.height - insets.top - insets.bottom), alignment: .topLeading)
                                }
                                .pinnedScrollInsets(insets)
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
                                    selectable: document.supportsChunkStaging,
                                    minimumWidth: geometry.size.width
                                )
                                ScrollView([.horizontal, .vertical]) {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        if document.hunks.isEmpty {
                                            Text(DiffLayoutMetrics.rawFallbackPreview(diff))
                                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        if document.supportsChunkStaging {
                                            PinnedHorizontalBar(scrollState: unifiedScroll, viewportWidth: geometry.size.width) {
                                                selectionBar(diff: diff, includesBackground: false)
                                            }
                                            .frame(minWidth: contentWidth, alignment: .leading)
                                            .background(.bar)
                                        }
                                        ForEach(prepared.unifiedItems) { item in
                                            switch item {
                                            case .hunkHeader(let preview):
                                                PinnedHorizontalBar(scrollState: unifiedScroll, viewportWidth: geometry.size.width) {
                                                    stashHunkHeader(preview, diff: diff, supportsChunkStaging: document.supportsChunkStaging, includesBackground: false)
                                                }
                                                .frame(minWidth: contentWidth, alignment: .leading)
                                                .background(Color.accentColor.opacity(0.06))
                                            case .line(let hunkID, let line, let isSelectableHunk):
                                                let lineKey = "\(hunkID):\(line.id)"
                                                UnifiedDiffLineRow(
                                                    line: line,
                                                    fontSize: preferences.diffFontSize,
                                                    code: prepared.code[hunkID]?[line.id],
                                                    query: matchedLineIDs.contains(lineKey) ? findQuery : "",
                                                    selected: lineSelection.contains(PatchLineID(hunk: hunkID, line: line.id)),
                                                    focused: focusedLine == lineKey,
                                                    showsSelectionSlot: isSelectableHunk,
                                                    minimumWidth: contentWidth,
                                                    select: isSelectableHunk ? { toggle(line, hunkID: hunkID, prepared: prepared) } : nil
                                                ).equatable()
                                            case .truncationNotice:
                                                PinnedHorizontalBar(scrollState: unifiedScroll, viewportWidth: geometry.size.width) {
                                                    Text("Preview limited to 8,000 lines.").font(.caption).foregroundStyle(.secondary).padding(12)
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
                        }
                    } top: {
                        DiffFindBar(query: $findQuery, matches: findMatches, selection: $focusedLine) { findReveal = UUID() }
                    }
                    .frame(height: min(520, max(160, CGFloat(previews.reduce(0) { $0 + $1.lines.count }) * 21 + CGFloat(document.hunks.count) * 30 + 90)))
                    .task(id: FindKey(patchID: prepared.id, query: findQuery)) {
                        guard !findQuery.isEmpty else {
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
                } else if let error { Text(error).foregroundStyle(.red).font(.caption).padding(12) }
                else { ProgressView().controlSize(.small).padding(12) }
            } label: {
                HStack(spacing: 9) {
                    Toggle("Select \(file.path)", isOn: $selected).labelsHidden().toggleStyle(.checkbox)
                    StatusBadge(status: file.status)
                    FilePathLabel(path: file.path).picoDrag(store, .stashFiles(stash, [file.path])).help("Drag to Working Copy to apply this file")
                    if file.isUntracked { Chip(text: String(localized: "Untracked"), tint: .teal) }
                    Spacer()
                    if let statistics { if statistics.isBinary { Chip(text: String(localized: "Binary"), tint: .secondary) } else { DiffStat(additions: statistics.additions, deletions: statistics.deletions) } }
                    Button("Apply File…") { store.stashAction(.files(stash, [file.path])) }.controlSize(.small)
                }.padding(.vertical, 8)
            }.padding(.horizontal, 14)
            .task(id: expanded) {
                guard expanded, diff == nil else { return }
                do {
                    let source = try await repository.stashFileDiff(stash, file: file), path = file.path
                    let value = await Task.detached(priority: .userInitiated) { PreparedPatch.make(source, path: path) }.value
                    guard !Task.isCancelled else { return }; prepared = value; diff = source
                } catch { self.error = error.localizedDescription }
            }
        }.frame(maxWidth: .infinity)
    }

    private func selectionBar(diff: String, includesBackground: Bool) -> some View {
        HStack {
            Text(lineSelection.isEmpty ? "Click the gutter to pick lines" : "\(lineSelection.count) lines selected").foregroundStyle(.secondary)
            Spacer()
            if !lineSelection.isEmpty {
                Button("Clear") { lineSelection = []; anchor = nil }
                Button("Apply Selected Lines…") { store.stashAction(.lines(stash, file, diff, lineSelection)) }
                Text("Drag Selected Lines").picoDrag(store, .stashLines(stash, file, diff, lineSelection)).help("Drag to Working Copy to apply selected lines")
            }
        }.font(.system(size: 10)).controlSize(.mini).padding(8).background { if includesBackground { Rectangle().fill(.bar) } }
    }

    private func stashHunkHeader(_ preview: PatchHunkPreview, diff: String, supportsChunkStaging: Bool, includesBackground: Bool) -> some View {
        HStack {
            Text(preview.hunk.header).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.accentColor.opacity(0.85)).lineLimit(1)
            Spacer()
            Button("Apply Chunk…") { store.stashAction(.chunk(stash, file, diff, preview.hunk.id)) }.controlSize(.mini).disabled(!supportsChunkStaging || preview.isTruncated)
        }.padding(.horizontal, 10).padding(.vertical, 6).background { if includesBackground { Color.accentColor.opacity(0.06) } }.picoDrag(store, .stashChunk(stash, file, diff, preview.hunk.id))
    }

    private func toggle(_ line: DiffLine, hunkID: Int, prepared: PreparedPatch) {
        guard !store.isBusy else { return }
        let key = PatchLineID(hunk: hunkID, line: line.id)
        if NSEvent.modifierFlags.contains(.shift), let anchor {
            let ordered = prepared.selectableOrder
            if let start = ordered.firstIndex(of: anchor), let end = ordered.firstIndex(of: key) { lineSelection.formUnion(ordered[min(start, end)...max(start, end)]) }
        } else if lineSelection.contains(key) { lineSelection.remove(key) } else { lineSelection.insert(key) }
        self.anchor = key
    }

}
