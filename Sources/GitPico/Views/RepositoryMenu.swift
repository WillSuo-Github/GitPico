import GitCore
import SwiftUI

struct RepositoryMenu: View {
    @Bindable var store: RepositoryStore
    var body: some View {
        Menu {
            Section {
                Button("Repositories…") { store.showingRepositoryLibrary = true }
                Button("Quick Open…") { store.showingQuickOpen = true }
            }
            Section {
                Button("Open Repository…", action: store.chooseRepository)
                Button("Clone Git Repository…") { store.creationRequest = RepositoryCreationRequest(clone: true) }
                Button("New Repository…") { store.creationRequest = RepositoryCreationRequest(clone: false) }
            }
            if !store.recentPaths.isEmpty {
                Section("Recent Repositories") {
                    ForEach(store.recentPaths, id: \.self) { path in
                        Button(store.library.displayName(for: path)) { Task { await store.open(URL(fileURLWithPath: path)) } }
                    }
                }
            }
        } label: { Label("Repositories", systemImage: "folder") }
        .help("Open a repository (⌘O)")
    }
}
