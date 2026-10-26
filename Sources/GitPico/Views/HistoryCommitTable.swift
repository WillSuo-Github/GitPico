import AppKit
import GitCore
import SwiftUI
import UniformTypeIdentifiers

/// Fixed row heights avoid measuring SwiftUI cells again on every branch change.
/// The store owns history and selection; the coordinator only indexes visible rows.
struct HistoryCommitTable: NSViewRepresentable {
    let store: RepositoryStore
    let presentation: HistoryPresentation
    let grouped: Bool
    let compact: Bool
    let showGraph: Bool
    let canModifyHistory: Bool
    let selection: String?
    let reveal: HistoryReveal?

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeView() }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let table = HistoryTableView()
        private var input: HistoryCommitTable?
        private var rows: [Row] = []
        private var commitRows: [String: Int] = [:]
        private var updating = false
        private var lastReveal: UUID?

        private enum Row {
            case month(id: String, title: String), commit(Commit)
            var id: String {
                switch self { case .month(let id, _): "month:" + id; case .commit(let commit): commit.hash }
            }
        }

        func makeView() -> NSScrollView {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = true
            scroll.backgroundColor = .textBackgroundColor
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
            table.addTableColumn(column)
            table.headerView = nil
            table.style = .plain
            table.backgroundColor = .textBackgroundColor
            table.intercellSpacing = .zero
            table.usesAutomaticRowHeights = false
            table.floatsGroupRows = false
            table.allowsEmptySelection = true
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.autoresizingMask = [.width]
            table.dataSource = self
            table.delegate = self
            table.setDraggingSourceOperationMask(.copy, forLocal: true)
            table.setDraggingSourceOperationMask([], forLocal: false)
            table.rowMenu = { [weak self] row in
                guard let self, let input = self.input, self.rows.indices.contains(row), case .commit(let commit) = self.rows[row] else { return nil }
                return NSHostingMenu(rootView: HistoryCommitActions(store: input.store, commit: commit, canModifyHistory: input.canModifyHistory))
            }
            table.setAccessibilityLabel("Commit history")
            scroll.documentView = table
            return scroll
        }

        func update(_ value: HistoryCommitTable) {
            let old = input
            input = value
            updating = true
            defer { updating = false }
            let replaced = old?.presentation.id != value.presentation.id || old?.grouped != value.grouped || old?.store !== value.store
            let restyled = old?.compact != value.compact || old?.showGraph != value.showGraph || old?.canModifyHistory != value.canModifyHistory
            let previousIDs = replaced ? rows.map(\.id) : []
            if replaced {
                rows = []
                commitRows = [:]
                if value.grouped {
                    for group in value.presentation.groups {
                        rows.append(.month(id: group.id, title: group.title))
                        append(group.commits)
                    }
                } else { append(value.presentation.page.commits) }
            }
            if old == nil || restyled { table.reloadData() }
            else if replaced {
                // Retain shared rows instead of tearing down the whole table.
                let difference = rows.map(\.id).difference(from: previousIDs)
                var removed = IndexSet(), inserted = IndexSet()
                for change in difference {
                    switch change {
                    case .remove(let offset, _, _): removed.insert(offset)
                    case .insert(let offset, _, _): inserted.insert(offset)
                    }
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0; context.allowsImplicitAnimation = false
                    table.beginUpdates()
                    table.removeRows(at: removed, withAnimation: [])
                    table.insertRows(at: inserted, withAnimation: [])
                    table.endUpdates()
                }
                let visible = table.rows(in: table.visibleRect)
                if visible.location != NSNotFound, visible.length > 0, visible.location < rows.count {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<min(rows.count, NSMaxRange(visible))), columnIndexes: IndexSet(integer: 0))
                }
            }
            let selectedRow = value.selection.flatMap { commitRows[$0] } ?? -1
            let previousRow = table.selectedRow
            if selectedRow != previousRow {
                if selectedRow >= 0 { table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false) }
                else { table.deselectAll(nil) }
                let changed = IndexSet([previousRow, selectedRow].filter { rows.indices.contains($0) })
                if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
            }
            if let reveal = value.reveal, reveal.id != lastReveal, let row = commitRows[reveal.hash], let scroll = table.enclosingScrollView {
                lastReveal = reveal.id
                let rect = table.rect(ofRow: row)
                let height = scroll.contentView.bounds.height
                let y = reveal.atTop ? rect.minY : rect.midY - height / 2
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, table.bounds.height - height))))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        private func append(_ commits: [Commit]) {
            for commit in commits {
                commitRows[commit.hash] = rows.count
                rows.append(.commit(commit))
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch rows[row] { case .month: 26; case .commit: input?.compact == true ? 32 : 50 }
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard let store = input?.store, !store.isBusy || store.isBackgroundFetching else { return false }
            if case .commit = rows[row] { return true }
            return false
        }
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            if case .month = rows[row] { return true }
            return false
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let input, (!input.store.isBusy || input.store.isBackgroundFetching), rows.indices.contains(table.selectedRow), case .commit(let commit) = rows[table.selectedRow] else { return }
            input.store.selectCommit(commit)
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard let input, !input.store.isBusy, rows.indices.contains(row), case .commit(let commit) = rows[row], let data = try? JSONEncoder().encode(input.store.makeDragToken(.commit(commit))) else { return nil }
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.picoDrag.identifier))
            return item
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let input else { return nil }
            switch rows[row] {
            case .month(_, let title):
                let id = NSUserInterfaceItemIdentifier("month")
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? NSTableCellView()
                if cell.textField == nil {
                    let label = NSTextField(labelWithString: "")
                    label.font = .systemFont(ofSize: 10, weight: .semibold)
                    label.textColor = .secondaryLabelColor
                    label.frame = NSRect(x: 12, y: 5, width: 260, height: 16)
                    label.autoresizingMask = [.width]
                    cell.addSubview(label); cell.textField = label; cell.identifier = id
                }
                cell.textField?.stringValue = title
                return cell
            case .commit(let commit):
                let content = HistoryCommitAppearance(commit: commit, graph: input.presentation.graph[commit.hash], graphWidth: CGFloat(input.presentation.graphWidth), compact: input.compact, showGraph: input.showGraph, selected: tableView.isRowSelected(row))
                let cell = tableView.makeView(withIdentifier: HistoryCommitCell.reuseID, owner: nil) as? HistoryCommitCell ?? HistoryCommitCell()
                cell.configure(content, store: input.store)
                return cell
            }
        }
    }
}

final class HistoryTableView: NSTableView {
    var rowMenu: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        rowMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

private struct HistoryCommitAppearance: Equatable {
    let commit: Commit
    let graph: GraphRow?
    let graphWidth: CGFloat
    let compact: Bool
    let showGraph: Bool
    let selected: Bool
}

/// Lightweight drawing keeps cached branch changes out of SwiftUI cell layout.
private final class HistoryCommitCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("commit")
    private var content: HistoryCommitAppearance?
    private let drop = NativePicoDropView(frame: .zero)
    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { needsDisplay = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseID
        drop.frame = bounds
        drop.autoresizingMask = [.width, .height]
        addSubview(drop)
        setAccessibilityElement(true)
    }
    required init?(coder: NSCoder) { nil }
    func configure(_ content: HistoryCommitAppearance, store: RepositoryStore) {
        if self.content != content { self.content = content; needsDisplay = true }
        let target = PicoDropTarget.commit(content.commit, .squash)
        drop.validate = { [weak store] in store?.canAcceptDrop($0, on: target) == true }
        drop.accept = { [weak store] in store?.acceptDrop($0, on: target, point: $1, height: $2) == true }
        setAccessibilityLabel(content.commit.subject + ", " + content.commit.author + ", " + content.commit.shortHash)
        toolTip = content.commit.subject + "\n" + content.commit.author + " · " + content.commit.date.formatted(date: .complete, time: .shortened)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        let commit = content.commit, compact = content.compact
        let selectedText: NSColor = window?.isKeyWindow == true ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor
        let primary: NSColor = content.selected ? selectedText : .labelColor
        let secondary: NSColor = content.selected ? selectedText.withAlphaComponent(0.75) : .secondaryLabelColor
        var x: CGFloat = 12
        if content.showGraph, let graph = content.graph {
            let width = min(content.graphWidth, CGFloat(max(1, graph.laneCount)) * 13 + 16, 110)
            drawGraph(graph, in: NSRect(x: 4, y: 2, width: width, height: bounds.height - 4))
            x = 4 + width + 9
        }
        let size: CGFloat = compact ? 20 : 26
        let avatar = NSRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
        let tint = NSColor(Pico.tint(for: commit.author))
        let circle = NSBezierPath(ovalIn: avatar)
        NSGradient(starting: tint.withAlphaComponent(0.85), ending: tint)?.draw(in: circle, angle: 90)
        NSColor.white.withAlphaComponent(0.18).setStroke(); circle.lineWidth = 0.5; circle.stroke()
        drawText(Pico.monogram(commit.author), in: avatar.insetBy(dx: 1, dy: size * 0.23), font: .systemFont(ofSize: size * 0.38, weight: .semibold), color: .white, alignment: .center)
        x += size + 9
        let top = compact ? (bounds.height - 16) / 2 : 7.0
        let badgeWidth = drawBadge(commit.decorations, y: top, selected: content.selected, textColor: selectedText)
        drawText(commit.subject, in: NSRect(x: x, y: top, width: max(0, bounds.width - 12 - x - badgeWidth), height: 17), font: .systemFont(ofSize: 12.5, weight: .medium), color: primary)
        if !compact {
            let date = commit.date.picoRelative
            let dateWidth = min(130, (date as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width)
            let dateRect = NSRect(x: max(x, bounds.width - 12 - dateWidth), y: 28, width: dateWidth, height: 15)
            drawText(date, in: dateRect, font: .systemFont(ofSize: 11), color: secondary, alignment: .right)
            let hashFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
            let hashText = " · " + commit.shortHash
            let hashWidth = (hashText as NSString).size(withAttributes: [.font: hashFont]).width
            let available = max(0, dateRect.minX - x - 9)
            let authorWidth = max(0, min((commit.author as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width, available - hashWidth))
            drawText(commit.author, in: NSRect(x: x, y: 28, width: authorWidth, height: 15), font: .systemFont(ofSize: 11), color: secondary)
            drawText(hashText, in: NSRect(x: x + authorWidth, y: 28, width: min(hashWidth, available - authorWidth), height: 15), font: hashFont, color: secondary)
        }
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        guard rect.width > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail; style.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private func drawBadge(_ decorations: [String], y: CGFloat, selected: Bool, textColor: NSColor) -> CGFloat {
        guard !decorations.isEmpty else { return 0 }
        let head = decorations.contains { $0.hasPrefix("HEAD") }
        let tag = !head && decorations.first?.hasPrefix("tag: ") == true
        let label = decorations.first(where: { $0.hasPrefix("HEAD -> ") }).map { String($0.dropFirst(8)) }
            ?? (head ? "HEAD" : (decorations.first ?? "").replacingOccurrences(of: "tag: ", with: ""))
        let tint = head ? NSColor.controlAccentColor : NSColor(tag ? Pico.warning : Pico.modified)
        let extra: CGFloat = decorations.count > 1 ? 22 : 0
        let width = min(108, (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold)]).width + 22)
        let rect = NSRect(x: max(0, bounds.width - 12 - width - extra), y: y + 1, width: width, height: 15)
        (selected ? textColor.withAlphaComponent(0.2) : head ? tint : tint.withAlphaComponent(0.15)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7.5, yRadius: 7.5).fill()
        let ink: NSColor = selected ? textColor : head ? .white : tint
        let image = NSImage(systemSymbolName: tag ? "tag.fill" : head ? "smallcircle.filled.circle" : "arrow.triangle.branch", accessibilityDescription: nil)
        image?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))?.withSymbolConfiguration(.init(paletteColors: [ink]))?.draw(in: NSRect(x: rect.minX + 4, y: rect.minY + 3, width: 9, height: 9), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        drawText(label, in: NSRect(x: rect.minX + 16, y: rect.minY + 1, width: width - 19, height: 13), font: .systemFont(ofSize: 9.5, weight: .semibold), color: ink)
        if decorations.count > 1 {
            drawText("+\(decorations.count - 1)", in: NSRect(x: rect.maxX + 3, y: rect.minY, width: 20, height: 15), font: .systemFont(ofSize: 9.5), color: selected ? textColor : .secondaryLabelColor)
        }
        return width + extra + 6
    }

    private func drawGraph(_ row: GraphRow, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: rect).addClip()
        let mid = rect.midY
        func x(_ lane: Int) -> CGFloat { rect.minX + CGFloat(lane) * 13 + 10 }
        func stroke(_ path: NSBezierPath, color: Int) {
            NSColor(Pico.laneColors[color % Pico.laneColors.count]).setStroke()
            path.lineWidth = 1.6; path.stroke()
        }
        for edge in row.incoming {
            let path = NSBezierPath(); path.move(to: NSPoint(x: x(edge.from), y: rect.minY)); path.line(to: NSPoint(x: x(edge.to), y: mid)); stroke(path, color: edge.color)
        }
        for edge in row.outgoing {
            let path = NSBezierPath(); path.move(to: NSPoint(x: x(edge.from), y: mid))
            path.curve(to: NSPoint(x: x(edge.to), y: rect.maxY), controlPoint1: NSPoint(x: x(edge.from), y: mid + 16), controlPoint2: NSPoint(x: x(edge.to), y: rect.maxY - 16)); stroke(path, color: edge.color)
        }
        let node = NSBezierPath(ovalIn: NSRect(x: x(row.lane) - 3.5, y: mid - 3.5, width: 7, height: 7))
        NSColor.textBackgroundColor.setFill(); node.fill(); stroke(node, color: row.color)
    }
}
