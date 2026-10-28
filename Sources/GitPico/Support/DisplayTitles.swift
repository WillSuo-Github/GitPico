import Foundation
import GitCore

// Raw values identify cases in Git, storage and comparisons; these titles are the localized display text.

extension AICommitLanguage {
    var title: LocalizedStringResource {
        switch self {
        case .english: "English"
        case .chinese: "Simplified Chinese"
        }
    }
}

extension HostingProvider {
    var title: LocalizedStringResource {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .generic: "Other HTTPS"
        }
    }
}

extension RepositoryInfrastructureMode {
    var title: LocalizedStringResource {
        switch self {
        case .move: "Move Main Repository"
        case .repair: "Repair Pointers"
        case .history: "Migration / Repair History"
        }
    }
}

extension QuickCommand {
    var title: LocalizedStringResource {
        switch self {
        case .lfs: "Git LFS"
        case .gitFlow: "Git Flow"
        case .flowFeature: "Start Git Flow Feature"
        case .flowRelease: "Start Git Flow Release"
        case .flowHotfix: "Start Git Flow Hotfix"
        case .moveMain: "Move Main Repository"
        case .repairPointers: "Repair Repository Pointers"
        case .infrastructureHistory: "Migration / Repair History"
        case .managementBackups: "Management Backups"
        case .worktree: "Add Worktree"
        case .submodule: "Add Submodule"
        case .refresh: "Refresh"
        case .repositories: "Repositories"
        case .quickOpen: "Quick Open"
        case .stageAll: "Stage All"
        case .unstageAll: "Unstage All"
        case .saveStash: "Save Stash"
        case .discard: "Discard All Local Changes"
        case .recover: "Recover Local Changes"
        case .applyPatch: "Apply Patch"
        case .branch: "Create Branch"
        case .tag: "Create Tag"
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .interactiveRebase: "Interactive Rebase"
        case .compare: "Compare Revisions"
        case .tools: "External Tool Settings"
        case .sessions: "External Tool Sessions"
        case .undo: "Undo Git Operation"
        case .redo: "Redo Git Operation"
        }
    }
}
