import AppKit
import GitCore
import SwiftUI

struct ChunkDiffView: View {
    let prepared: PreparedPatch?
    var isLoading = false
    var chunkAction: ((Int) -> Void)? = nil
    var lineAction: ((Set<PatchLineID>) -> Void)? = nil
    var actionTitle = "Stage Chunk"
    var leftTitle = "Original"
    var rightTitle = "Changed"
    var disabled = false
    var discardChunk: ((Int) -> Void)? = nil
    var discardLines: ((Set<PatchLineID>) -> Void)? = nil
    var exportLines: ((Set<PatchLineID>) -> Void)? = nil
    @State private var preferences = AppPreferences.shared
    @State private var selectedLines = PatchLineSelection()
    private var text: String { prepared?.source ?? "" }

    var body: some View {
        Group {
        if isLoading && prepared == nil { ProgressView("Loading changes…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        else if text.isEmpty { EmptyPane(title: "No textual changes", subtitle: "Select the other diff version if this file is partially staged.", icon: "doc.text.magnifyingglass") }
        else if let prepared {
            let patch = prepared.patch
            let previews = prepared.previews
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    DiffStat(additions: patch.additions, deletions: patch.deletions)
                    Text("\(patch.hunks.count) \(patch.hunks.count == 1 ? "chunk" : "chunks")").foregroundStyle(.secondary)
                    Spacer()
                    if lineAction != nil, patch.supportsChunkStaging {
                        if selectedLines.ids.isEmpty {
                            Label("Click the gutter to pick lines", systemImage: "hand.point.up.left").foregroundStyle(.tertiary)
                        } else {
                            Text("\(selectedLines.ids.count) \(selectedLines.ids.count == 1 ? "line" : "lines") selected").foregroundStyle(.secondary)
                            Menu {
                                Button("Clear Selection") { selectedLines.clear() }
                                if let exportLines { Button("Save Lines as Patch…") { exportLines(selectedLines.ids) } }
                            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            if let discardLines { Button("Discard Lines…", role: .destructive) { discardLines(selectedLines.ids) } }
                            Button(actionTitle.hasPrefix("Unstage") ? "Unstage Lines" : "Stage Lines") { lineAction?(selectedLines.ids) }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.return, modifiers: [.command, .shift])
                        }
                    }
                }.font(.system(size: 11)).controlSize(.small).padding(.horizontal, 14).frame(height: 34).disabled(disabled)
                Divider()
                GeometryReader { geometry in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if preferences.splitDiff {
                                HStack(spacing: 0) { Text(leftTitle).frame(maxWidth: .infinity, alignment: .leading); Text(rightTitle).frame(maxWidth: .infinity, alignment: .leading) }.font(.system(size: 10, weight: .semibold)).textCase(.uppercase).tracking(0.5).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 24)
                            }
                            if patch.hunks.isEmpty { Text(text).font(.system(size: preferences.diffFontSize, design: .monospaced)).textSelection(.enabled).padding(12) }
                            ForEach(previews) { preview in
                                let hunk = preview.hunk
                                let canSelect = lineAction != nil && patch.supportsChunkStaging && !preview.isTruncated
                                HStack {
                                    Text(hunk.header).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.accentColor.opacity(0.85)).lineLimit(1)
                                    Spacer()
                                    if let discardChunk, patch.supportsChunkStaging {
                                        Button("Discard Chunk…", role: .destructive) { discardChunk(hunk.id) }.controlSize(.mini).disabled(disabled || preview.isTruncated)
                                    }
                                    if let chunkAction, patch.supportsChunkStaging {
                                        Button(actionTitle) { chunkAction(hunk.id) }.controlSize(.mini).disabled(disabled || preview.isTruncated)
                                    }
                                }.padding(.horizontal, 12).frame(height: 30).background(Color.accentColor.opacity(0.06)).overlay(alignment: .top) { Divider().opacity(0.6) }
                                if preferences.splitDiff {
                                    SplitDiffView(lines: preview.lines, fontSize: preferences.diffFontSize, preparedRows: prepared.splitRows[hunk.id], selected: Set(selectedLines.ids.filter { $0.hunk == hunk.id }.map(\.line)), select: canSelect ? { toggle($0, in: hunk, prepared: prepared) } : nil, minimumWidth: geometry.size.width)
                                } else {
                                    ScrollView(.horizontal) {
                                        LazyVStack(alignment: .leading, spacing: 0) {
                                            ForEach(preview.lines) { line in
                                                HStack(spacing: 0) {
                                                    if canSelect, line.kind == .addition || line.kind == .deletion {
                                                        LineSelectionButton(line: line, selected: selectedLines.ids.contains(PatchLineID(hunk: hunk.id, line: line.id)), action: { toggle(line, in: hunk, prepared: prepared) })
                                                    } else if canSelect { Color.clear.frame(width: 25) }
                                                    DiffLineView(line: line, fontSize: preferences.diffFontSize)
                                                }.frame(minWidth: geometry.size.width, alignment: .leading)
                                                    .background(selectedLines.ids.contains(PatchLineID(hunk: hunk.id, line: line.id)) ? Color.accentColor.opacity(0.23) : .clear)
                                            }
                                        }
                                    }
                                }
                            }
                            if previews.count < patch.hunks.count || previews.last?.isTruncated == true { Text("Preview limited to 8,000 lines. Review the complete diff in an external tool.").font(.caption).foregroundStyle(.secondary).padding(12) }
                        }.frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }.defaultScrollAnchor(.topLeading)
                }.background(Color(nsColor: .textBackgroundColor))
            }
        }
        }
        .disabled(disabled || isLoading)
        .onChange(of: text) { selectedLines.clear() }
        .onChange(of: leftTitle) { selectedLines.clear() }
    }

    func toggle(_ line: DiffLine, in hunk: PatchHunk, prepared: PreparedPatch) {
        guard !disabled, !isLoading else { return }
        selectedLines.toggle(PatchLineID(hunk: hunk.id, line: line.id), extending: NSEvent.modifierFlags.contains(.shift), order: prepared.selectableOrder)
    }

}

extension PatchDocument {
    var summary: String {
        "\(hunks.count) \(hunks.count == 1 ? "chunk" : "chunks"), \(additions) \(additions == 1 ? "insertion" : "insertions"), \(deletions) \(deletions == 1 ? "deletion" : "deletions")"
    }
}
