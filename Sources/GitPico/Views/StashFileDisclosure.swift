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
    @State private var error: String?
    @State private var width: CGFloat = 0
    @State private var preferences = AppPreferences.shared
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            DisclosureGroup(isExpanded: $expanded) {
                if let diff {
                    if statistics?.isBinary == true { Text("Binary file — apply the whole file to restore its exact contents.").font(.caption).foregroundStyle(.secondary).padding(16) }
                    else {
                        let document = PatchDocument(diff)
                        if document.hunks.isEmpty { Text(diff).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                        if document.supportsChunkStaging {
                            HStack {
                                Text(lineSelection.isEmpty ? "Click the gutter to pick lines" : "\(lineSelection.count) lines selected").foregroundStyle(.secondary)
                                Spacer()
                                if !lineSelection.isEmpty {
                                    Button("Clear") { lineSelection = []; anchor = nil }
                                    Button("Apply Selected Lines…") { store.stashAction(.lines(stash, file, diff, lineSelection)) }
                                    Text("Drag Selected Lines").picoDrag(store, .stashLines(stash, file, diff, lineSelection)).help("Drag to Working Copy to apply selected lines")
                                }
                            }.font(.system(size: 10)).controlSize(.mini).padding(8).background(.bar)
                        }
                        ForEach(document.preview()) { preview in
                            VStack(spacing: 0) {
                                HStack {
                                    Text(preview.hunk.header).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.accentColor.opacity(0.85)).lineLimit(1)
                                    Spacer()
                                    Button("Apply Chunk…") { store.stashAction(.chunk(stash, file, diff, preview.hunk.id)) }.controlSize(.mini).disabled(!document.supportsChunkStaging || preview.isTruncated)
                                }.padding(.horizontal, 10).padding(.vertical, 6).background(Color.accentColor.opacity(0.06)).picoDrag(store, .stashChunk(stash, file, diff, preview.hunk.id))
                                if preferences.splitDiff { SplitDiffView(lines: preview.lines, fontSize: preferences.diffFontSize, selected: Set(lineSelection.filter { $0.hunk == preview.hunk.id }.map(\.line)), select: document.supportsChunkStaging && !preview.isTruncated ? { toggle($0, in: preview.hunk, document: document) } : nil, minimumWidth: max(0, width - 28)) }
                                else { ScrollView(.horizontal) { VStack(alignment: .leading, spacing: 0) { ForEach(preview.lines) { line in
                                    HStack(spacing: 0) {
                                        if document.supportsChunkStaging && !preview.isTruncated {
                                            if line.kind == .addition || line.kind == .deletion {
                                                LineSelectionButton(line: line, selected: lineSelection.contains(PatchLineID(hunk: preview.hunk.id, line: line.id))) { toggle(line, in: preview.hunk, document: document) }
                                            } else { Color.clear.frame(width: 25) }
                                        }
                                        DiffLineView(line: line, fontSize: preferences.diffFontSize)
                                    }.frame(minWidth: max(0, width - 28), alignment: .leading)
                                    .background(lineSelection.contains(PatchLineID(hunk: preview.hunk.id, line: line.id)) ? Color.accentColor.opacity(0.23) : .clear)
                                } } } }
                            }
                        }
                    }
                } else if let error { Text(error).foregroundStyle(.red).font(.caption).padding(12) }
                else { ProgressView().controlSize(.small).padding(12) }
            } label: {
                HStack(spacing: 9) {
                    Toggle("Select \(file.path)", isOn: $selected).labelsHidden().toggleStyle(.checkbox)
                    StatusBadge(status: file.status)
                    FilePathLabel(path: file.path).picoDrag(store, .stashFiles(stash, [file.path])).help("Drag to Working Copy to apply this file")
                    if file.isUntracked { Chip(text: "Untracked", tint: .teal) }
                    Spacer()
                    if let statistics { if statistics.isBinary { Chip(text: "Binary", tint: .secondary) } else { DiffStat(additions: statistics.additions, deletions: statistics.deletions) } }
                    Button("Apply File…") { store.stashAction(.files(stash, [file.path])) }.controlSize(.small)
                }.padding(.vertical, 8)
            }.padding(.horizontal, 14)
            .task(id: expanded) { guard expanded, diff == nil else { return }; do { diff = try await repository.stashFileDiff(stash, file: file) } catch { self.error = error.localizedDescription } }
        }.frame(maxWidth: .infinity).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
    private func toggle(_ line: DiffLine, in hunk: PatchHunk, document: PatchDocument) {
        guard !store.isBusy else { return }
        let key = PatchLineID(hunk: hunk.id, line: line.id)
        if NSEvent.modifierFlags.contains(.shift), let anchor {
            let ordered = document.preview().filter { !$0.isTruncated }.flatMap { preview in
                preview.lines.compactMap { line -> PatchLineID? in
                    line.kind == .addition || line.kind == .deletion ? PatchLineID(hunk: preview.hunk.id, line: line.id) : nil
                }
            }
            if let start = ordered.firstIndex(of: anchor), let end = ordered.firstIndex(of: key) { lineSelection.formUnion(ordered[min(start, end)...max(start, end)]) }
        } else if lineSelection.contains(key) { lineSelection.remove(key) } else { lineSelection.insert(key) }
        self.anchor = key
    }

}
