import SwiftUI

struct RepositoryMenu: View {
    @Bindable var store: RepositoryStore
    var body: some View {
        Button(action: store.showRepositories) { Label("Repositories", systemImage: "folder") }
            .help("Choose a repository in the current tab")
            .disabled(store.isBusy || store.isOpeningRepository)
    }
}
