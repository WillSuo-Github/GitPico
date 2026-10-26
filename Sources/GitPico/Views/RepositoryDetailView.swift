import GitCore
import SwiftUI

struct RepositoryDetailView: View {
    @Bindable var store: RepositoryStore
    var body: some View {
        switch store.destination {
        case .worktrees: WorktreesView(store: store)
        case .submodules: SubmodulesView(store: store)
        case .workingCopy: WorkingCopyView(store: store)
        case .history, .reference: HistoryView(store: store)
        case .reflog: ReflogView(store: store)
        case .stashes: StashesView(store: store)
        case .branchesReview: BranchesReviewView(store: store)
        case .repositorySettings: RepositorySettingsView(store: store)
        case .fileHistory(let path, let revision):
            if let repository = store.repository { FileHistoryView(store: store, repository: repository, path: path, revision: revision).id(store.repositoryToken.uuidString + path + revision) }
        case .comparison(let left):
            if let repository = store.repository { RevisionComparisonView(store: store, repository: repository, initialLeft: left).id(store.repositoryToken.uuidString + left) }
        }
    }
}
