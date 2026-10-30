import GitCore
import SwiftUI

struct SidebarWorktreeRow: View {
    let store: RepositoryStore
    let entry: ManagedWorktree
    var isCurrent: Bool { entry.path == store.snapshot?.root.path }
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(store.worktreeTitle(entry)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if entry.isMain { Chip(text: String(localized: "Main"), tint: .secondary) }
                    if isCurrent { Chip(text: String(localized: "Current"), tint: .accentColor) }
                }
                Text(store.worktreePresentation.location(for: entry)).font(.system(size: 10))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        } icon: {
            Image(systemName: entry.locked != nil ? "lock" : "folder.badge.gearshape")
        }
        .padding(.leading, 12).padding(.vertical, 2).contentShape(Rectangle())
        .disabled(entry.prunable != nil)
        .help(entry.path + "\n" + (store.worktreePresentation.branch(for: entry) ?? String(localized: "Detached HEAD")))
        .contextMenu { WorktreeContextActions(store: store, entry: entry) }
    }
}
