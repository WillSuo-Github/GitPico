import Foundation
import GitCore

struct SidebarContextSelection {
    let destinations: Set<Destination>
    let references: [Reference]
    init(_ destinations: Set<Destination>, references: [Reference]) {
        self.destinations = destinations
        self.references = references.filter { destinations.contains(.reference($0.fullName)) }
            .sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
    }
    var onlyReferences: Bool { !destinations.isEmpty && references.count == destinations.count }
    var onlyLocalBranches: Bool { onlyReferences && references.allSatisfy(\.isLocal) }
    var canDelete: Bool { onlyReferences && references.allSatisfy { $0.isLocal || $0.isTag } && !references.contains(where: \.isCurrent) }
    var copiedNames: String { references.map(\.name).joined(separator: "\n") }
}

extension RepositoryStore {
    func organize(_ references: [Reference], archived: Bool? = nil, pinned: Bool? = nil, repositoryToken expected: UUID) {
        guard expected == repositoryToken else { error = String(localized: "The repository changed. Reopen this preview."); return }
        perform("Updating branch organization…") { try await $0.setReferenceOrganization(references, archived: archived, pinned: pinned) }
    }
    func reviewSidebarReferenceDeletion(_ references: [Reference], repositoryToken expected: UUID) {
        guard expected == repositoryToken else { error = String(localized: "The repository changed. Reopen this preview."); return }
        manage(.deleteReferences(references, repositoryToken: expected))
    }
    func deleteSidebarReferences(_ references: [Reference], force: Bool, repositoryToken expected: UUID) {
        guard expected == repositoryToken else { error = String(localized: "The repository changed. Reopen this preview."); return }
        perform("Deleting references…") { try await $0.deleteReferences(references, force: force) }
    }
}
