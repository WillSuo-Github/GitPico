import SwiftUI

struct WelcomeView: View {
    var store: RepositoryStore
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "arrow.triangle.merge").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 92, height: 92).background(Pico.brand, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Pico.brandBottom.opacity(0.3), radius: 16, y: 8).padding(.bottom, 4)
            Text("GitPico").font(.system(size: 38, weight: .bold, design: .rounded))
            Text("A little clarity for every commit.").font(.title3).foregroundStyle(.secondary)
            Button(action: store.chooseRepository) { Label("Open Repository…", systemImage: "folder") }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("o")
            HStack { Button("Repositories…") { store.showingRepositoryLibrary = true }; Button("Quick Open…") { store.showingQuickOpen = true } }
            Button("Repair Repository Pointers…") { store.infrastructure(.repair) }
            if let error = store.library.error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: 500) }
            if !store.recentPaths.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionCaption("Recent Repositories")
                    ForEach(store.recentPaths.prefix(5), id: \.self) { path in
                        Button { Task { await store.open(URL(fileURLWithPath: path)) } } label: {
                            HStack { RepositoryGlyph(name: store.library.displayName(for: path), size: 24); Text(store.library.displayName(for: path)); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                                .contentShape(Rectangle()).padding(.vertical, 5)
                        }.buttonStyle(.plain).help(path)
                    }
                }.frame(width: 320).padding(.top, 20)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(store.isBusy)
    }
}
