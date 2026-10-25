import Foundation

public struct SplitDiffRow: Identifiable, Sendable {
    public let id: Int
    public let left: DiffLine?
    public let right: DiffLine?

    public static func align(_ lines: [DiffLine]) -> [SplitDiffRow] {
        var result: [SplitDiffRow] = []
        var deleted: [DiffLine] = []; var added: [DiffLine] = []
        func flush() {
            for index in 0..<max(deleted.count, added.count) {
                result.append(SplitDiffRow(id: result.count, left: index < deleted.count ? deleted[index] : nil, right: index < added.count ? added[index] : nil))
            }
            deleted = []; added = []
        }
        for line in lines {
            switch line.kind {
            case .deletion:
                if !added.isEmpty { flush() }
                deleted.append(line)
            case .addition: added.append(line)
            default:
                flush(); result.append(SplitDiffRow(id: result.count, left: line, right: line))
            }
        }
        flush()
        return result
    }
}
