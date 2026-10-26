import Foundation

public struct GraphEdge: Sendable, Equatable {
    public let from: Int
    public let to: Int
    public let color: Int
}

public struct GraphRow: Sendable, Equatable {
    public let lane: Int
    public let color: Int
    public let incoming: [GraphEdge]
    public let outgoing: [GraphEdge]
    public let laneCount: Int
}

public enum CommitGraph {
    // Lanes are assigned to actual parent hashes; no decorative/fabricated branches.
    public static func layout(_ commits: [Commit], firstParentOnly: Bool = false) -> [String: GraphRow] {
        var lanes: [(hash: String, color: Int)] = []
        var colors = 0
        var rows: [String: GraphRow] = [:]
        for commit in commits {
            let parents = firstParentOnly ? Array(commit.parents.prefix(1)) : commit.parents
            let existing = lanes
            if !lanes.contains(where: { $0.hash == commit.hash }) {
                lanes.append((commit.hash, colors)); colors += 1
            }
            let before = lanes
            let lane = before.firstIndex(where: { $0.hash == commit.hash })!
            let color = before[lane].color
            lanes.remove(at: lane)
            for (offset, parent) in parents.enumerated() {
                if !lanes.contains(where: { $0.hash == parent }) {
                    lanes.insert((parent, offset == 0 ? color : colors), at: min(lane + offset, lanes.count))
                    if offset != 0 { colors += 1 }
                }
            }
            var incoming: [GraphEdge] = []
            var outgoing: [GraphEdge] = []
            for (index, item) in before.enumerated() {
                if existing.contains(where: { $0.hash == item.hash }) {
                    incoming.append(GraphEdge(from: index, to: index, color: item.color))
                }
                if index != lane, let after = lanes.firstIndex(where: { $0.hash == item.hash }) {
                    outgoing.append(GraphEdge(from: index, to: after, color: item.color))
                }
            }
            for parent in parents {
                if let target = lanes.firstIndex(where: { $0.hash == parent }) {
                    outgoing.append(GraphEdge(from: lane, to: target, color: lanes[target].color))
                }
            }
            rows[commit.hash] = GraphRow(lane: lane, color: color, incoming: incoming, outgoing: outgoing, laneCount: max(before.count, lanes.count))
        }
        return rows
    }
}
