import SwiftUI

struct RepositoryPickerSidebarView: View {
    @Bindable var workspace: RepositoryWorkspace
    @Bindable var tab: RepositoryTab
    var body: some View {
        List(selection: Binding<RepositoryLibraryFilter?>(get: { tab.pickerFilter }, set: { if let value = $0 { tab.pickerFilter = value } })) {
            Section("Library") {
                Label("Recent", systemImage: "clock").tag(RepositoryLibraryFilter.recent)
                Label("Favorites", systemImage: "star").badge(workspace.library.matches(filter: .favorites).count).tag(RepositoryLibraryFilter.favorites)
                Label("All Repositories", systemImage: "square.stack").badge(workspace.library.matches(filter: .all).count).tag(RepositoryLibraryFilter.all)
            }
            if !workspace.library.orderedGroups.isEmpty {
                Section("Groups") {
                    ForEach(workspace.library.orderedGroups) { group in
                        Label(workspace.library.breadcrumb(group.id), systemImage: "folder").tag(RepositoryLibraryFilter.group(group.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(tab.isBusy)
    }
}
