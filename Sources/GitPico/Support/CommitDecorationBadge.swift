struct CommitDecorationBadge {
    let label: String
    let isHead: Bool
    let isTag: Bool
    let inlineLabel: String

    init(_ decorations: [String]) {
        // Git's pretty format uses these two forms for attached and detached HEAD.
        let head = decorations.firstIndex { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") }
        isHead = head != nil
        let primary = head ?? decorations.startIndex
        let first = decorations.indices.contains(primary) ? decorations[primary] : ""
        isTag = !isHead && first.hasPrefix("tag: ")
        label = isHead ? "HEAD" : Self.name(first)
        if let next = decorations.indices.first(where: { $0 != primary }) {
            inlineLabel = label + " · " + Self.name(decorations[next]) + (decorations.count > 2 ? " · …" : "")
        } else {
            inlineLabel = label
        }
    }

    private static func name(_ decoration: String) -> String {
        decoration.hasPrefix("tag: ") ? String(decoration.dropFirst(5)) : decoration
    }
}
