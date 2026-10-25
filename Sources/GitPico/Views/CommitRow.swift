import AppKit
import GitCore
import SwiftUI

private let graphColors: [Color] = [.blue, .pink, .green, .orange, .purple, .teal, .indigo]

struct CommitRow: View {
    @Environment(\.controlActiveState) private var controlActiveState
    private var selectionColor: Color { Color(nsColor: controlActiveState == .key ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor) }
    let commit: Commit
    let graph: GraphRow?
    let graphWidth: CGFloat
    var compact = false
    var showGraph = true
    let selected: Bool
    var canModifyHistory = true
    var cherryPick: (() -> Void)? = nil
    var interactiveRebase: (() -> Void)? = nil
    var restore: (() -> Void)? = nil
    var recoverBranch: (() -> Void)? = nil
    var revert: (() -> Void)? = nil
    var compare: (() -> Void)? = nil
    var savePatch: (() -> Void)? = nil
    var exportFiles: (() -> Void)? = nil
    var archiveFiles: (() -> Void)? = nil
    var fileActions: HistoricalFileMenu? = nil
    var body: some View {
        HStack(spacing: 8) {
                if let graph, showGraph { GraphCell(row: graph).frame(width: min(graphWidth, 110), height: compact ? 30 : 48).clipped() }
                Text(commit.initials).font(.system(size: 11, weight: .medium)).foregroundStyle(selected ? selectionColor.opacity(0.8) : .secondary)
                    .frame(width: compact ? 22 : 30, height: compact ? 22 : 30).background(.quaternary, in: Circle())
                VStack(alignment: .leading, spacing: compact ? 0 : 3) {
                    HStack(spacing: 5) {
                        Text(commit.author).font(.system(size: compact ? 10 : 11)).foregroundStyle(selected ? selectionColor.opacity(0.8) : .secondary).lineLimit(1)
                        if !commit.decorations.isEmpty {
                            CommitReferenceBadge(decorations: commit.decorations, selected: selected)

                        }
                        Spacer(minLength: 0)
                        Text(commit.date, format: .dateTime.month(.twoDigits).day(.twoDigits).year(.twoDigits)).font(.system(size: 10)).foregroundStyle(selected ? selectionColor.opacity(0.7) : .secondary).fixedSize().lineLimit(1)
                    }
                    HStack(spacing: 7) {
                        Text(commit.shortHash).font(.system(size: 10, design: .monospaced)).foregroundStyle(selected ? selectionColor.opacity(0.7) : .secondary)
                        Text(commit.subject).font(.system(size: 12)).foregroundStyle(selected ? selectionColor : .primary).lineLimit(1).help(commit.subject)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.leading, graph == nil || !showGraph ? 12 : 4).padding(.trailing, 12).frame(height: compact ? 32 : 48)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(commit.subject + ", " + commit.author + ", " + commit.shortHash)
        .contextMenu {
            Section {
            if let cherryPick { Button("Cherry-Pick Commit…", action: cherryPick) }
            if let revert { Button("Revert Commit…", action: revert) }
            if let compare { Button("Compare with Revision…", action: compare) }
            if let interactiveRebase { Button("Interactively Rebase from Here…", action: interactiveRebase) }
            if let restore { Button("Restore HEAD Here…", action: restore) }
            if let recoverBranch { Button("Create Branch Here…", action: recoverBranch) }
            }.disabled(!canModifyHistory)
            Section {
            if let fileActions { fileActions }
            if let exportFiles { Button("Export Files at Revision…", action: exportFiles) }
            if let archiveFiles { Button("Archive Files as ZIP…", action: archiveFiles) }
            if let savePatch { Button("Save Patch as File…", action: savePatch) }
            }
            Section {
            Button("Copy Commit Hash") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.hash, forType: .string) }
            Button("Copy Commit Subject") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.subject, forType: .string) }
            }
        }
    }
}

struct CommitReferenceBadge: View {
    @Environment(\.controlActiveState) private var controlActiveState
    private var selectionColor: Color { Color(nsColor: controlActiveState == .key ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor) }
    let decorations: [String]
    let selected: Bool
    var label: String { decorations.contains { $0.hasPrefix("HEAD") } ? "HEAD" : (decorations.first ?? "").replacingOccurrences(of: "tag: ", with: "") }
    var isTag: Bool { !decorations.contains { $0.hasPrefix("HEAD") } && decorations.first?.hasPrefix("tag: ") == true }
    var body: some View {
        HStack(spacing: 3) {
            Text(label).lineLimit(1).truncationMode(.middle).padding(.horizontal, 4).padding(.vertical, 1)
                .background((isTag ? Color.orange : Color.accentColor).opacity(selected ? 0.7 : 0.18), in: RoundedRectangle(cornerRadius: 3))
            if decorations.count > 1 { Text("+\(decorations.count - 1)").foregroundStyle(selected ? selectionColor.opacity(0.8) : .secondary) }
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(selected ? selectionColor : (isTag ? .orange : .accentColor))
        .frame(maxWidth: 95).help(decorations.joined(separator: ", "))
    }
}

struct GraphCell: View {
    let row: GraphRow
    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            func x(_ lane: Int) -> CGFloat { CGFloat(lane) * 13 + 10 }
            for edge in row.incoming {
                var path = Path(); path.move(to: CGPoint(x: x(edge.from), y: 0)); path.addLine(to: CGPoint(x: x(edge.to), y: middle))
                context.stroke(path, with: .color(graphColors[edge.color % graphColors.count]), lineWidth: 1.6)
            }
            for edge in row.outgoing {
                var path = Path(); path.move(to: CGPoint(x: x(edge.from), y: middle))
                path.addCurve(to: CGPoint(x: x(edge.to), y: size.height), control1: CGPoint(x: x(edge.from), y: middle + 16), control2: CGPoint(x: x(edge.to), y: size.height - 16))
                context.stroke(path, with: .color(graphColors[edge.color % graphColors.count]), lineWidth: 1.6)
            }
            let node = Path(ellipseIn: CGRect(x: x(row.lane) - 3.5, y: middle - 3.5, width: 7, height: 7))
            context.fill(node, with: .color(Color(nsColor: .textBackgroundColor)))
            context.stroke(node, with: .color(graphColors[row.color % graphColors.count]), lineWidth: 2)
        }.accessibilityLabel("Commit graph, lane \(row.lane + 1)")
    }
}
