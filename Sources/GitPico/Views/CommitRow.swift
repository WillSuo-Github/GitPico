import AppKit
import GitCore
import SwiftUI

private let graphColors: [Color] = Pico.laneColors

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
    var secondary: Color { selected ? selectionColor.opacity(0.75) : .secondary }
    var body: some View {
        HStack(spacing: 9) {
                if let graph, showGraph {
                    GraphCell(row: graph)
                        .frame(width: min(graphWidth, CGFloat(max(1, graph.laneCount)) * 13 + 16, 110), height: compact ? 30 : 46)
                        .clipped()
                }
                AuthorAvatar(name: commit.author, size: compact ? 20 : 26)
                VStack(alignment: .leading, spacing: compact ? 0 : 3) {
                    HStack(spacing: 6) {
                        Text(commit.subject).font(.system(size: 12.5, weight: .medium)).foregroundStyle(selected ? selectionColor : .primary).lineLimit(1).help(commit.subject)
                        Spacer(minLength: 0)
                        if !commit.decorations.isEmpty {
                            CommitReferenceBadge(decorations: commit.decorations, selected: selected)
                        }
                    }
                    if !compact {
                        HStack(spacing: 5) {
                            Text(commit.author).lineLimit(1)
                            Text("·").foregroundStyle(secondary.opacity(0.6))
                            Text(commit.shortHash).font(.system(size: 10.5, design: .monospaced))
                            Spacer(minLength: 0)
                            Text(commit.date.picoRelative).fixedSize().lineLimit(1).help(commit.date.formatted(date: .complete, time: .shortened))
                        }.font(.system(size: 11)).foregroundStyle(secondary)
                    }
                }
            }
            .padding(.leading, graph == nil || !showGraph ? 12 : 4).padding(.trailing, 12).frame(height: compact ? 32 : 50)
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
    var isHead: Bool { decorations.contains { $0.hasPrefix("HEAD") } }
    var label: String {
        if let head = decorations.first(where: { $0.hasPrefix("HEAD -> ") }) { return String(head.dropFirst(8)) }
        return isHead ? "HEAD" : (decorations.first ?? "").replacingOccurrences(of: "tag: ", with: "")
    }
    var isTag: Bool { !isHead && decorations.first?.hasPrefix("tag: ") == true }
    var tint: Color { isHead ? .accentColor : isTag ? Pico.warning : Pico.modified }
    var body: some View {
        HStack(spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: isTag ? "tag.fill" : isHead ? "smallcircle.filled.circle" : "arrow.triangle.branch").imageScale(.small)
                Text(label).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .foregroundStyle(selected ? selectionColor : (isHead ? .white : tint))
            .background(selected ? AnyShapeStyle(selectionColor.opacity(0.2)) : isHead ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.15)), in: Capsule())
            if decorations.count > 1 { Text("+\(decorations.count - 1)").foregroundStyle(selected ? selectionColor.opacity(0.8) : .secondary) }
        }
        .font(.system(size: 9.5, weight: .semibold))
        .frame(maxWidth: 130, alignment: .trailing).fixedSize(horizontal: false, vertical: true).help(decorations.joined(separator: ", "))
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
