import Foundation

/// Stored operation identifiers stay stable; translate only at the display boundary.
func operationStateTitle(_ state: String) -> LocalizedStringResource {
    switch state {
    case "applied": "Applied"
    case "applying": "Applying"
    case "restored": "Restored"
    case "restoring": "Restoring"
    case "completed": "Completed"
    case "pending": "Pending"
    case "running": "Running"
    case "failed": "Failed"
    case "stopped": "Stopped"
    case "prepared": "Prepared"
    case "ready": "Ready"
    case "skipped": "Skipped"
    case "cancelled": "Cancelled"
    case "paused": "Paused"
    case "reconnecting": "Reconnecting"
    case "needsRepair": "Repair Needed"
    default: LocalizedStringResource("\(state)")
    }
}

func networkCommandTitle(_ command: String) -> LocalizedStringResource {
    switch command {
    case "fetch": "Fetch"
    case "pull": "Pull"
    case "push": "Push"
    case "clone": "Clone"
    default: LocalizedStringResource("\(command)")
    }
}
