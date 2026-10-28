import Foundation

/// Looks up user-facing GitCore text in GitCore's string catalog. Never use it for data written to Git.
func localized(_ value: String.LocalizationValue) -> String { String(localized: value, bundle: #bundle) }

/// Display text for a stable file status name or a Git status letter.
public func localizedFileStatus(_ status: String) -> String {
    switch status {
    case "Conflict", "U": localized("Conflict")
    case "Untracked", "?": localized("Untracked")
    case "Added", "A": localized("Added")
    case "Modified", "M": localized("Modified")
    case "Deleted", "D": localized("Deleted")
    case "Renamed", "R": localized("Renamed")
    case "Copied", "C": localized("Copied")
    case "Type changed", "T": localized("Type changed")
    case "Changed": localized("Changed")
    case "Ignored": localized("Ignored")
    case "Skip Worktree": localized("Skip Worktree")
    case "Assume Unchanged": localized("Assume Unchanged")
    case "Unmodified": localized("Unmodified")
    default: status
    }
}
