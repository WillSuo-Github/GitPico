import Foundation

// Raw values identify cases in Git, storage and comparisons; these titles are the localized display text.

extension SubmoduleDirectoryMode {
    public var title: String {
        switch self {
        case .newDirectory: localized("New Directory")
        case .emptyDirectory: localized("Existing Empty Directory")
        case .existingRepository: localized("Existing Repository")
        case .retainedRepository: localized("Retained Git Repository")
        case .archiveAndClone: localized("Back Up Retained Repository and Clone Fresh")
        }
    }
}

extension SubmoduleOperation {
    public var title: String {
        switch self {
        case .forceDeinitialize: localized("Force Deinitialize (Keep Backup)")
        case .forceRemove: localized("Force Remove (Keep Backup)")
        case .archiveStorage: localized("Archive Retained Git Storage")
        case .initialize: localized("Initialize / Checkout Recorded Version")
        case .update: localized("Update to Recorded Version")
        case .fetch: localized("Fetch")
        case .sync: localized("Synchronize URLs")
        case .checkout: localized("Checkout Revision")
        case .setURL: localized("Change URL")
        case .move: localized("Move Submodule")
        case .repair: localized("Repair Git Configuration")
        case .deinitialize: localized("Deinitialize")
        case .remove: localized("Remove Submodule")
        }
    }
    /// Menu and progress title, e.g. "Fetch…".
    public var actionTitle: String {
        switch self {
        case .forceDeinitialize: localized("Force Deinitialize (Keep Backup)…")
        case .forceRemove: localized("Force Remove (Keep Backup)…")
        case .archiveStorage: localized("Archive Retained Git Storage…")
        case .initialize: localized("Initialize / Checkout Recorded Version…")
        case .update: localized("Update to Recorded Version…")
        case .fetch: localized("Fetch…")
        case .sync: localized("Synchronize URLs…")
        case .checkout: localized("Checkout Revision…")
        case .setURL: localized("Change URL…")
        case .move: localized("Move Submodule…")
        case .repair: localized("Repair Git Configuration…")
        case .deinitialize: localized("Deinitialize…")
        case .remove: localized("Remove Submodule…")
        }
    }
}

extension WorktreeBatchOperation {
    public var title: String {
        switch self {
        case .lock: localized("Lock")
        case .unlock: localized("Unlock")
        case .move: localized("Move")
        case .remove: localized("Remove")
        case .forceRemove: localized("Force Remove (Keep Backup)")
        case .forceUnlockRemove: localized("Unlock and Force Remove (Keep Backup)")
        case .prune: localized("Prune Missing Registrations")
        }
    }
}

extension RepositoryOperation {
    public var title: String {
        switch self {
        case .none: localized("Integration")
        case .merge: localized("Merge")
        case .rebase: localized("Rebase")
        case .cherryPick: localized("Cherry-Pick")
        case .revert: localized("Revert")
        }
    }
    public var inProgressTitle: String {
        switch self {
        case .none: localized("Integration in progress")
        case .merge: localized("Merge in progress")
        case .rebase: localized("Rebase in progress")
        case .cherryPick: localized("Cherry-pick in progress")
        case .revert: localized("Revert in progress")
        }
    }
}

extension GitRepository.Integration {
    public var title: String {
        switch self {
        case .merge: localized("Merge")
        case .rebase: localized("Rebase")
        case .cherryPick: localized("Cherry-Pick")
        case .revert: localized("Revert")
        }
    }
    public var progressTitle: String {
        switch self {
        case .merge: localized("Merge…")
        case .rebase: localized("Rebase…")
        case .cherryPick: localized("Cherry-Pick…")
        case .revert: localized("Revert…")
        }
    }
}

extension RebaseAction {
    public var title: String {
        switch self {
        case .pick: localized("Pick")
        case .reword: localized("Reword")
        case .edit: localized("Edit")
        case .squash: localized("Squash")
        case .fixup: localized("Fixup")
        case .drop: localized("Drop")
        }
    }
}

extension GitSignatureState {
    public var title: String {
        switch self {
        case .valid: localized("Valid signature")
        case .untrusted: localized("Valid signature, untrusted identity")
        case .invalid: localized("Invalid signature")
        case .expired: localized("Expired signature or key")
        case .revoked: localized("Revoked key")
        case .unverifiable: localized("Cannot verify signature")
        case .unsigned: localized("Unsigned")
        }
    }
}

extension LFSTransfer {
    public var title: String {
        switch self {
        case .fetch: localized("Fetch Objects")
        case .pull: localized("Pull Objects")
        case .push: localized("Push Objects")
        case .checkout: localized("Checkout Cached Objects")
        }
    }
}

extension GitFlowKind {
    public var title: String {
        switch self {
        case .feature: localized("Feature")
        case .release: localized("Release")
        case .hotfix: localized("Hotfix")
        case .support: localized("Support")
        }
    }
    public var startTitle: String {
        switch self {
        case .feature: localized("Start Feature")
        case .release: localized("Start Release")
        case .hotfix: localized("Start Hotfix")
        case .support: localized("Start Support")
        }
    }
    public var finishTitle: String {
        switch self {
        case .feature: localized("Finish Feature")
        case .release: localized("Finish Release")
        case .hotfix: localized("Finish Hotfix")
        case .support: localized("Finish Support")
        }
    }
}

extension GitRepository.IgnoreFile {
    public var title: String {
        switch self {
        case .ignores: localized("Ignores")
        case .excludes: localized("Excludes")
        }
    }
}

extension GitNetworkEvent.Phase {
    public var title: String {
        switch self {
        case .running: localized("Running")
        case .succeeded: localized("Succeeded")
        case .failed: localized("Failed")
        case .cancelled: localized("Cancelled")
        }
    }
}
