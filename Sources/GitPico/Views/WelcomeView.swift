import SwiftUI

struct WelcomeView: View {
    var store: RepositoryStore
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 58, weight: .light)).foregroundStyle(.tint).padding(.bottom, 4)
            Text("GitPico").font(.system(size: 38, weight: .bold, design: .rounded))
            Text("A little clarity for every commit.").font(.title3).foregroundStyle(.secondary)
            Button(action: store.chooseRepository) { Label("Open Repository…", systemImage: "folder") }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("o")
            HStack { Button("Repositories…") { store.showingRepositoryLibrary = true }; Button("Quick Open…") { store.showingQuickOpen = true } }
            Button("Repair Repository Pointers…") { store.infrastructure(.repair) }
            if let error = store.library.error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: 500) }
            if !store.recentPaths.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT REPOSITORIES").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    ForEach(store.recentPaths.prefix(5), id: \.self) { path in
                        Button { Task { await store.open(URL(fileURLWithPath: path)) } } label: {
                            HStack { Image(systemName: "folder").foregroundStyle(.tint); Text(store.library.displayName(for: path)); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                                .contentShape(Rectangle()).padding(.vertical, 5)
                        }.buttonStyle(.plain).help(path)
                    }
                }.frame(width: 320).padding(.top, 20)
            }
            Text("SwiftUI · macOS 26+").font(.caption).foregroundStyle(.tertiary).padding(.top, 12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(store.isBusy)
    }
}
