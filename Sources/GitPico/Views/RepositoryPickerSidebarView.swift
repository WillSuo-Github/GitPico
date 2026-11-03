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
            let accounts = workspace.authentication.profiles.filter { $0.repositoryProvider != nil }
            if !accounts.isEmpty {
                Section("Remote Repositories") {
                    ForEach(accounts) { account in
                        Label(account.repositoryAccountLabel, systemImage: "cloud")
                            .help(account.label)
                            .tag(RepositoryLibraryFilter.account(account.id))
                    }
                }
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
