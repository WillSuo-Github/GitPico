import AppKit
import GitCore
import SwiftUI

struct DiffView: View {
    let text: String
    let title: String?
    var subtitle: String = ""
    var isLoading = false
    var showsHeader = true
    var scrollTopInset: CGFloat = 0
    var initialPrepared: PreparedDiff? = nil
    @State private var preferences = AppPreferences.shared
    @State private var prepared: PreparedDiff?
    @State private var preparedInput: DiffInputKey?
    @State private var findQuery = ""
    @State private var focusedLine: String?
    @State private var findReveal = UUID()
    @State private var findMatches: [String] = []
    @State private var matchedLineIDs: Set<String> = []
    @State private var splitScroll = SplitHorizontalScrollState()

    private struct DiffInputKey: Equatable {
        let text: String
        let title: String?
    }

    private struct FindKey: Equatable {
        let diffID: UUID?
        let query: String
    }

    var body: some View {
        let inputKey = DiffInputKey(text: text, title: title)
        let currentPrepared = preparedInput == inputKey ? prepared : (preparedInput == nil ? initialPrepared : nil)
        PinnedScrollPane { insets in
            if isLoading {
                ProgressView("Loading changes…").frame(maxWidth: .infinity, maxHeight: .infinity).padding(insets)
            } else if title == nil {
                EmptyPane(title: String(localized: "No file selected"), subtitle: String(localized: "Select a file to inspect its changes."), icon: "doc").padding(insets)
            } else if text.isEmpty {
                EmptyPane(title: String(localized: "No textual changes"), subtitle: String(localized: "This file may have only metadata or conflict changes."), icon: "doc.text.magnifyingglass").padding(insets)
            } else if let currentPrepared {
                ScrollViewReader { proxy in
                Group {
                if preferences.splitDiff {
                    GeometryReader { geometry in
                        let layout = DiffLayoutMetrics.splitLayout(
                            leftColumns: currentPrepared.maxSplitLeftColumns,
                            rightColumns: currentPrepared.maxSplitRightColumns,
                            fontSize: preferences.diffFontSize,
                            selectable: false,
                            totalWidth: geometry.size.width
                        )
                        let rowHeight = DiffLayoutMetrics.splitRowHeight(fontSize: preferences.diffFontSize)
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(currentPrepared.splitRows) { row in
                                    let leftKey = row.left.map { "line:\($0.id)" }
                                    let rightKey = row.right.map { "line:\($0.id)" }
                                    SplitDiffRowView(
                                        row: row,
                                        fontSize: preferences.diffFontSize,
                                        halfWidth: layout.halfWidth,
                                        rowHeight: rowHeight,
                                        leftCode: row.left.flatMap { currentPrepared.code[$0.id] },
                                        rightCode: row.right.flatMap { currentPrepared.code[$0.id] },
                                        leftSelected: false,
                                        rightSelected: false,
                                        leftFocused: leftKey != nil && focusedLine == leftKey,
                                        rightFocused: rightKey != nil && focusedLine == rightKey,
                                        leftQuery: leftKey.map { matchedLineIDs.contains($0) ? findQuery : "" } ?? "",
                                        rightQuery: rightKey.map { matchedLineIDs.contains($0) ? findQuery : "" } ?? "",
                                        showsSelectionSlot: false,
                                        scrollState: splitScroll,
                                        select: nil
                                    )
                                    .equatable()
                                    .id("split:line:\(row.id)")
                                }
                                if currentPrepared.isTruncated {
                                    Text("Preview limited to 8,000 lines.").font(.caption).foregroundStyle(.secondary).padding(12)
                                }
                            }
                            .frame(minWidth: geometry.size.width, minHeight: max(0, geometry.size.height - insets.top - insets.bottom), alignment: .topLeading)
                        }.pinnedScrollInsets(insets)
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
                    }
                } else { GeometryReader { geometry in
                    let contentWidth = DiffLayoutMetrics.unifiedContentWidth(
                        columns: currentPrepared.maxUnifiedColumns,
                        fontSize: preferences.diffFontSize,
                        selectable: false,
                        minimumWidth: geometry.size.width
                    )
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(currentPrepared.lines) { line in
                                let lineKey = "line:\(line.id)"
                                DiffLineView(
                                    line: line,
                                    fontSize: preferences.diffFontSize,
                                    code: currentPrepared.code[line.id],
                                    query: matchedLineIDs.contains(lineKey) ? findQuery : ""
                                )
                                .equatable()
                                .frame(minWidth: contentWidth, alignment: .leading)
                                .id(lineKey)
                                .overlay { if focusedLine == lineKey { Rectangle().strokeBorder(Color.accentColor, lineWidth: 1) } }
                            }
                            if currentPrepared.isTruncated {
                                Text("Preview limited to 8,000 lines. Copy the diff to inspect the complete output.")
                                    .font(.caption).foregroundStyle(.secondary).padding(14)
                            }
                        }
                        .padding(.vertical, 7)
                        .frame(minWidth: contentWidth, minHeight: max(0, geometry.size.height - insets.top - insets.bottom), alignment: .topLeading)
                    }
                    .defaultScrollAnchor(.topLeading).pinnedScrollInsets(insets)
                } }
                }.onChange(of: findReveal) {
                    guard let focusedLine else { return }
                    let target = preferences.splitDiff ? (currentPrepared.splitScrollTargets[focusedLine] ?? focusedLine) : focusedLine
                    proxy.scrollTo(target, anchor: .center)
                }
                }
            } else {
                ProgressView("Loading changes…").frame(maxWidth: .infinity, maxHeight: .infinity).padding(insets)
            }
        } top: {
            if let title, showsHeader {
                FileTitleBar(path: title, subtitle: subtitle, hasBackground: false) {
                    DiffLayoutPicker()
                    Button { Pico.copy(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy diff")
                }
            }
            if !isLoading, title != nil, !text.isEmpty {
                DiffFindBar(query: $findQuery, matches: findMatches, selection: $focusedLine) { findReveal = UUID() }
            }
        }.padding(.top, scrollTopInset).background(.background)
            .task(id: inputKey) {
                guard !text.isEmpty else {
                    prepared = nil
                    preparedInput = inputKey
                    return
                }
                if let initialPrepared, preparedInput == nil {
                    prepared = initialPrepared
                    preparedInput = inputKey
                    return
                }
                let source = text
                let path = title
                let value = await Task.detached(priority: .userInitiated) { PreparedDiff.make(source, path: path) }.value
                guard !Task.isCancelled else { return }
                prepared = value
                preparedInput = inputKey
                splitScroll.reset()
            }
            .task(id: FindKey(diffID: currentPrepared?.id, query: findQuery)) {
                guard let currentPrepared, !findQuery.isEmpty else {
                    findMatches = []
                    matchedLineIDs = []
                    return
                }
                let query = findQuery
                let matches = await Task.detached(priority: .userInitiated) { currentPrepared.matchingLineIDs(query: query) }.value
                guard !Task.isCancelled else { return }
                findMatches = matches
                matchedLineIDs = Set(matches)
            }
    }
}

struct DiffLineView: View, Equatable {
    let line: DiffLine
    let fontSize: Double
    var code: DiffCodeLine? = nil
    var query = ""
    var tint: Color {
        switch line.kind {
        case .addition: Pico.addition
        case .deletion: Pico.deletion
        case .hunk: .accentColor
        default: .clear
        }
    }
    var isChange: Bool { line.kind == .addition || line.kind == .deletion }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 0) {
                Text(line.oldNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing).padding(.trailing, 6)
                Text(line.newNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing).padding(.trailing, 8)
            }
            .foregroundStyle(isChange ? AnyShapeStyle(tint.opacity(0.9)) : AnyShapeStyle(.tertiary))
            .background(tint.opacity(isChange ? 0.10 : 0))
            .progressiveScrollBlur()
            HStack(spacing: 0) {
                if [.context, .addition, .deletion].contains(line.kind) { Text(String(line.text.prefix(1))).foregroundStyle(.secondary) }
                DiffCodeText(line: code ?? DiffCodeLine(source: CodeHighlighting.source(line), path: ""), query: query).equatable()
            }.foregroundStyle(line.kind == .metadata ? Color.secondary : line.kind == .hunk ? Color.accentColor.opacity(0.9) : Color.primary)
                .padding(.leading, 10).padding(.trailing, 20)
            Spacer(minLength: 0)
        }
        .font(.system(size: fontSize, design: .monospaced)).padding(.vertical, 1.5)
        .background(tint.opacity(line.kind == .hunk ? 0.06 : 0.11))
        .overlay(alignment: .leading) { if isChange { Rectangle().fill(tint).frame(width: 2) } }
        .environment(\.layoutDirection, .leftToRight)
    }
}

extension DiffLine {
    /// Raw `diff --git` / `index` / `---` / `+++` lines repeat what the title bar already shows.
    var isFileHeader: Bool {
        kind == .metadata && (text.hasPrefix("diff --git ") || text.hasPrefix("index ") || text.hasPrefix("--- ") || text.hasPrefix("+++ "))
    }
}

/// File name first, folder second; trailing slot for per-view controls.
struct FileTitleBar<Trailing: View>: View {
    let path: String
    var subtitle: String = ""
    var status: String? = nil
    var hasBackground = true
    @ViewBuilder var trailing: Trailing
    var folder: String { (path as NSString).deletingLastPathComponent }
    var body: some View {
        HStack(spacing: 9) {
            if let status { StatusBadge(status: status) } else { Image(systemName: "doc.text").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                let detail = [folder, subtitle].filter { !$0.isEmpty }.joined(separator: "  ·  ")
                if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }.help(path)
            Spacer(minLength: 8)
            trailing
        }
        .font(.system(size: 12)).padding(.horizontal, 14).frame(height: Pico.headerHeight)
        .background { if hasBackground { Rectangle().fill(.bar) } }
        .overlay(alignment: .bottom) { if hasBackground { Divider() } }
    }
}

struct EmptyPane: View {
    let title: String
    let subtitle: String
    let icon: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 26, weight: .regular)).foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).multilineTextAlignment(.center)
            if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320) }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
