import Foundation
import GitCore

struct ReferenceNode: Identifiable, Sendable {
    let id: String
    let name: String
    let reference: Reference?
    let children: [ReferenceNode]?
    static func build(_ references: [Reference], prefix: String = "", strip: String = "") -> [ReferenceNode] {
        let groups = Dictionary(grouping: references) { ref in String(ref.name.dropFirst(strip.count + prefix.count).split(separator: "/").first ?? "") }
        return groups.keys.sorted { left, right in
            let l = groups[left]?.contains { $0.name == strip + prefix + left } == true
            let r = groups[right]?.contains { $0.name == strip + prefix + right } == true
            return l != r ? l : left.localizedStandardCompare(right) == .orderedAscending
        }.map { name in
            let group = groups[name] ?? []
            let ref = group.first { $0.name == strip + prefix + name }
            return ReferenceNode(id: strip + prefix + name, name: name, reference: ref, children: ref == nil ? build(group, prefix: prefix + name + "/", strip: strip) : nil)
        }
    }
}

struct SidebarOutlineInput: Equatable, Sendable {
    var references: [Reference]
    var remotes: [String]
    var pinned: Set<String>
    var archived: Set<String>
    var filter: String
}
struct SidebarOutline: Sendable {
    var pinned: [Reference] = []
    var branches: [ReferenceNode] = []
    var archived: [ReferenceNode] = []
    var tags: [ReferenceNode] = []
    var remotes: [String:[ReferenceNode]] = [:]
    static let empty = SidebarOutline()
    nonisolated static func make(_ input: SidebarOutlineInput) -> Self {
        let refs = input.references.filter { input.filter.isEmpty || $0.name.localizedCaseInsensitiveContains(input.filter) }
        let local = refs.filter(\.isLocal)
        let remotes = Dictionary(uniqueKeysWithValues: input.remotes.map { remote in
            let branches = refs.filter { $0.isRemote && $0.name.hasPrefix(remote + "/") && !$0.name.hasSuffix("/HEAD") }
            return (remote, ReferenceNode.build(branches, strip: remote + "/"))
        })
        return Self(pinned: local.filter { input.pinned.contains($0.fullName) && !input.archived.contains($0.fullName) },
                    branches: ReferenceNode.build(local.filter { !input.pinned.contains($0.fullName) && !input.archived.contains($0.fullName) }),
                    archived: ReferenceNode.build(local.filter { input.archived.contains($0.fullName) }),
                    tags: ReferenceNode.build(refs.filter(\.isTag)),
                    remotes: remotes)
    }
}
