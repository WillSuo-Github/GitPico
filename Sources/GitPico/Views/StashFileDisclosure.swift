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
                        Group {
                            if document.hunks.isEmpty {
                                ScrollView([.horizontal, .vertical]) {
                                    Text(DiffLayoutMetrics.rawFallbackPreview(diff))
                                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .defaultScrollAnchor(.topLeading).pinnedScrollInsets(insets)
                            } else {
                                NativeDiffTable(
                                    source: .patch(
                                        prepared: prepared,
                                        showsColumnHeader: false,
                                        leftTitle: "",
                                        rightTitle: "",
                                        canSelectLines: document.supportsChunkStaging,
                                        hunkPrimaryActionTitle: String(localized: "Apply Chunk…"),
                                        hunkSecondaryDestructiveTitle: nil,
                                        supportsHunkDrag: true,
                                        showsStashSelectionBar: document.supportsChunkStaging,
                                        truncationMessage: String(localized: "Preview limited to 8,000 lines.")
                                    ),
                                    splitMode: preferences.splitDiff,
                                    fontSize: preferences.diffFontSize,
                                    selectedLines: lineSelection,
                                    focusedLine: focusedLine,
                                    findQuery: findQuery,
                                    matchedLineIDs: matchedLineIDs,
                                    findReveal: findReveal,
                                    disabled: store.isBusy,
                                    insets: insets,
                                    actions: NativeDiffActions(
                                        onToggleLine: document.supportsChunkStaging ? { hunkID, line in toggle(line, hunkID: hunkID, prepared: prepared) } : nil,
                                        onPrimaryChunkAction: { hunkID in store.stashAction(.chunk(stash, file, diff, hunkID)) },
                                        onHunkDragToken: { hunkID in store.makeDragToken(.stashChunk(stash, file, diff, hunkID)) },
                                        onClearStashSelection: { lineSelection = []; anchor = nil },
                                        onApplyStashLines: { store.stashAction(.lines(stash, file, diff, lineSelection)) },
                                        onStashLinesDragToken: { store.makeDragToken(.stashLines(stash, file, diff, lineSelection)) }
                                    )
                                )
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
