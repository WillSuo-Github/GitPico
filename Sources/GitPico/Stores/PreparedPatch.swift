import Foundation
import GitCore

enum UnifiedDiffListItem: Identifiable, Sendable {
    case hunkHeader(PatchHunkPreview)
    case line(hunkID: Int, line: DiffLine, isSelectableHunk: Bool)
    case truncationNotice

    var id: String {
        switch self {
        case .hunkHeader(let preview): "hunk:\(preview.id)"
        case .line(let hunkID, let line, _): "\(hunkID):\(line.id)"
        case .truncationNotice: "truncation"
        }
    }
}

enum SplitDiffListItem: Identifiable, Sendable {
    case hunkHeader(PatchHunkPreview)
    case row(hunkID: Int, row: SplitDiffRow, isSelectableHunk: Bool)
    case truncationNotice

    var id: String {
        switch self {
        case .hunkHeader(let preview): "split-hunk:\(preview.id)"
        case .row(let hunkID, let row, _): "split:\(hunkID):\(row.id)"
        case .truncationNotice: "split-truncation"
        }
    }
}

struct PreparedPatch: Sendable {
    let id: UUID
    let source: String
    let patch: PatchDocument
    let previews: [PatchHunkPreview]
    let splitRows: [Int:[SplitDiffRow]]
    let selectableOrder: [PatchLineID]
    let code: [Int: [Int: DiffCodeLine]]
    let unifiedItems: [UnifiedDiffListItem]
    let splitItems: [SplitDiffListItem]
    let splitScrollTargets: [String: String]
    let maxUnifiedColumns: Int
    let maxSplitLeftColumns: Int
    let maxSplitRightColumns: Int
    let isTruncated: Bool
    var isBinary: Bool { patch.isBinary }

    nonisolated static func make(_ source: String, path explicitPath: String? = nil) -> Self {
        let patch = PatchDocument(source)
        let previews = patch.preview()
        let path = explicitPath ?? CodeHighlighting.path(in: source)
        let truncated = previews.count < patch.hunks.count || previews.last?.isTruncated == true

        var order: [PatchLineID] = []
        var splitMap: [Int: [SplitDiffRow]] = [:]
        var codeMap: [Int: [Int: DiffCodeLine]] = [:]
        var unified: [UnifiedDiffListItem] = []
        var split: [SplitDiffListItem] = []
        var scrollTargets: [String: String] = [:]
        var maxUnified = 0
        var maxLeft = 0
        var maxRight = 0

        let totalPreviewLines = previews.reduce(0) { $0 + $1.lines.count }
        unified.reserveCapacity(totalPreviewLines + previews.count + (truncated ? 1 : 0))
        split.reserveCapacity(totalPreviewLines + previews.count + (truncated ? 1 : 0))
        scrollTargets.reserveCapacity(totalPreviewLines)
        splitMap.reserveCapacity(previews.count)
        codeMap.reserveCapacity(previews.count)

        for preview in previews {
            let hunkID = preview.id
            let selectableHunk = patch.supportsChunkStaging && !preview.isTruncated
            let aligned = SplitDiffRow.align(preview.lines)
            let preparedCode = CodeHighlighting.prepare(preview.lines, path: path, alignedRows: aligned)
            splitMap[hunkID] = aligned
            codeMap[hunkID] = preparedCode

            unified.append(.hunkHeader(preview))
            split.append(.hunkHeader(preview))

            for line in preview.lines {
                unified.append(.line(hunkID: hunkID, line: line, isSelectableHunk: selectableHunk))
                if selectableHunk, line.kind == .addition || line.kind == .deletion {
                    order.append(PatchLineID(hunk: hunkID, line: line.id))
                }
                let lineSource = preparedCode[line.id]?.source ?? CodeHighlighting.source(line)
                let columns = DiffCodeText.displayedColumnWidth(of: lineSource)
                if columns > maxUnified { maxUnified = columns }
            }

            for row in aligned {
                let rowTarget = "split:\(hunkID):\(row.id)"
                split.append(.row(hunkID: hunkID, row: row, isSelectableHunk: selectableHunk))
                if let left = row.left {
                    scrollTargets["\(hunkID):\(left.id)"] = rowTarget
                    let leftSource = preparedCode[left.id]?.source ?? CodeHighlighting.source(left)
                    let columns = DiffCodeText.displayedColumnWidth(of: leftSource)
                    if columns > maxLeft { maxLeft = columns }
                }
                if let right = row.right {
                    scrollTargets["\(hunkID):\(right.id)"] = rowTarget
                    let rightSource = preparedCode[right.id]?.source ?? CodeHighlighting.source(right)
                    let columns = DiffCodeText.displayedColumnWidth(of: rightSource)
                    if columns > maxRight { maxRight = columns }
                }
            }
        }

        if truncated {
            unified.append(.truncationNotice)
            split.append(.truncationNotice)
        }

        return Self(
            id: UUID(),
            source: source,
            patch: patch,
            previews: previews,
            splitRows: splitMap,
            selectableOrder: order,
            code: codeMap,
            unifiedItems: unified,
            splitItems: split,
            splitScrollTargets: scrollTargets,
            maxUnifiedColumns: maxUnified,
            maxSplitLeftColumns: maxLeft,
            maxSplitRightColumns: maxRight,
            isTruncated: truncated
        )
    }

    nonisolated func matchingLineIDs(query: String) -> [String] {
        guard !query.isEmpty else { return [] }
        var result: [String] = []
        for preview in previews {
            let hunkCode = code[preview.id]
            for line in preview.lines {
                let text = hunkCode?[line.id]?.source ?? CodeHighlighting.source(line)
                if CodeHighlighting.contains(text, query: query) {
                    result.append("\(preview.id):\(line.id)")
                }
            }
        }
        return result
    }
}

struct PreparedDiff: Sendable {
    let id: UUID
    let lines: [DiffLine]
    let splitRows: [SplitDiffRow]
    let splitScrollTargets: [String: String]
    let isTruncated: Bool
    let code: [Int: DiffCodeLine]
    let maxUnifiedColumns: Int
    let maxSplitLeftColumns: Int
    let maxSplitRightColumns: Int

    nonisolated static func make(_ text: String, path explicitPath: String?) -> Self {
        let document = DiffDocument(text)
        let visibleLines = document.lines.filter { !$0.isFileHeader }
        let resolvedPath = explicitPath ?? CodeHighlighting.path(in: text)
        let aligned = SplitDiffRow.align(visibleLines)
        let preparedCode = CodeHighlighting.prepare(visibleLines, path: resolvedPath, alignedRows: aligned)

        var maxUnified = 0
        for line in visibleLines {
            let lineSource = preparedCode[line.id]?.source ?? CodeHighlighting.source(line)
            let columns = DiffCodeText.displayedColumnWidth(of: lineSource)
            if columns > maxUnified { maxUnified = columns }
        }

        var scrollTargets: [String: String] = [:]
        scrollTargets.reserveCapacity(visibleLines.count)
        var maxLeft = 0
        var maxRight = 0
        for row in aligned {
            let rowTarget = "split:line:\(row.id)"
            if let left = row.left {
                scrollTargets["line:\(left.id)"] = rowTarget
                let leftSource = preparedCode[left.id]?.source ?? CodeHighlighting.source(left)
                let columns = DiffCodeText.displayedColumnWidth(of: leftSource)
                if columns > maxLeft { maxLeft = columns }
            }
            if let right = row.right {
                scrollTargets["line:\(right.id)"] = rowTarget
                let rightSource = preparedCode[right.id]?.source ?? CodeHighlighting.source(right)
                let columns = DiffCodeText.displayedColumnWidth(of: rightSource)
                if columns > maxRight { maxRight = columns }
            }
        }

        return Self(
            id: UUID(),
            lines: visibleLines,
            splitRows: aligned,
            splitScrollTargets: scrollTargets,
            isTruncated: document.isTruncated,
            code: preparedCode,
            maxUnifiedColumns: maxUnified,
            maxSplitLeftColumns: maxLeft,
            maxSplitRightColumns: maxRight
        )
    }

    nonisolated func matchingLineIDs(query: String) -> [String] {
        guard !query.isEmpty else { return [] }
        var result: [String] = []
        for line in lines {
            let text = code[line.id]?.source ?? CodeHighlighting.source(line)
            if CodeHighlighting.contains(text, query: query) {
                result.append("line:\(line.id)")
            }
        }
        return result
    }
}
struct PatchLineSelection {
    var ids: Set<PatchLineID> = []
    var anchor: PatchLineID?
    mutating func clear() { ids = []; anchor = nil }
    mutating func toggle(_ key: PatchLineID, extending: Bool, order: [PatchLineID]) {
        guard order.contains(key) else { return }
        if extending, let anchor, let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: key) {
            ids.formUnion(order[min(start,end)...max(start,end)])
        } else if ids.contains(key) { ids.remove(key) } else { ids.insert(key) }
        anchor = key
    }
}
