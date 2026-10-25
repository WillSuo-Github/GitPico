import Foundation
import GitCore

struct PreparedPatch: Sendable {
    let source: String
    let patch: PatchDocument
    let previews: [PatchHunkPreview]
    let splitRows: [Int:[SplitDiffRow]]
    let selectableOrder: [PatchLineID]
    nonisolated static func make(_ source: String) -> Self {
        let patch = PatchDocument(source), previews = patch.preview()
        let order = patch.supportsChunkStaging ? previews.filter { !$0.isTruncated }.flatMap { preview in
            preview.lines.compactMap { line in
                line.kind == .addition || line.kind == .deletion ? PatchLineID(hunk: preview.id, line: line.id) : nil
            }
        } : []
        return Self(source: source, patch: patch, previews: previews, splitRows: Dictionary(uniqueKeysWithValues: previews.map { ($0.id, SplitDiffRow.align($0.lines)) }), selectableOrder: order)
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
