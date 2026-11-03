struct CommitDecorationBadge {
    let label: String
    let isHead: Bool
    let isTag: Bool

    init(_ decorations: [String]) {
        // Git's pretty format uses these two forms for attached and detached HEAD.
        isHead = decorations.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") }
        let first = decorations.first ?? ""
        isTag = !isHead && first.hasPrefix("tag: ")
        label = isHead ? "HEAD" : isTag ? String(first.dropFirst(5)) : first
    }
}
