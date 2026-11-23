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
                Group {
                    if patch.hunks.isEmpty {
                        ScrollView([.horizontal, .vertical]) {
                            VStack(alignment: .leading, spacing: 0) {
                                if preferences.splitDiff {
                                    HStack(spacing: 0) {
                                        Text(leftTitle).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(rightTitle).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                                    .foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 24)
                                    .environment(\.layoutDirection, .leftToRight)
                                }
                                Text(DiffLayoutMetrics.rawFallbackPreview(prepared.source))
                                    .font(.system(size: preferences.diffFontSize, design: .monospaced))
                                    .textSelection(.enabled).padding(12)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .defaultScrollAnchor(.topLeading).pinnedScrollInsets(insets)
                    } else {
                        NativeDiffTable(
                            source: .patch(
                                prepared: prepared,
                                showsColumnHeader: true,
                                leftTitle: leftTitle,
                                rightTitle: rightTitle,
                                canSelectLines: canSelectAny,
                                hunkPrimaryActionTitle: chunkAction != nil ? actionTitle : nil,
                                hunkSecondaryDestructiveTitle: discardChunk != nil ? String(localized: "Discard Chunk…") : nil,
                                supportsHunkDrag: false,
                                showsStashSelectionBar: false,
                                truncationMessage: String(localized: "Preview limited to 8,000 lines. Review the complete diff in an external tool.")
                            ),
                            splitMode: preferences.splitDiff,
                            fontSize: preferences.diffFontSize,
                            selectedLines: selectedLines.ids,
                            focusedLine: focusedLine,
                            findQuery: findQuery,
                            matchedLineIDs: matchedLineIDs,
                            findReveal: findReveal,
                            disabled: disabled || isLoading,
                            insets: insets,
                            actions: NativeDiffActions(
                                onToggleLine: canSelectAny ? { hunkID, line in toggle(line, hunkID: hunkID, prepared: prepared) } : nil,
                                onPrimaryChunkAction: chunkAction,
                                onSecondaryChunkAction: discardChunk
                            )
                        )
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
