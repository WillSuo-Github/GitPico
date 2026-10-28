import AppKit
import GitCore

extension RepositoryStore {
    func chooseLibraryRepository(relocating id: UUID? = nil) {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = id == nil ? String(localized: "Add Local Repository") : String(localized: "Locate Repository")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = id == nil ? String(localized: "Add Repository") : String(localized: "Use Location")
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, !self.isBusy else { return }
                self.isBusy = true; self.activity = String(localized: "Checking repository…")
                defer { self.isBusy = false; self.activity = "" }
                do {
                    let repository = try await GitRepository.open(url), root = await repository.root
                    if let id { try self.library.relocate(id, to: root) }
                    else { try self.library.register(root) }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    func openSavedRepository(_ entry: SavedRepository) async {
        guard !isBusy, let current = library.document.repositories.first(where: { $0.id == entry.id }), current.path == entry.path else {
            if !isBusy { error = String(localized: "The saved repository changed. Refresh the repository list.") }
            return
        }
        await open(URL(fileURLWithPath: current.path))
    }
}

struct RepositoryQuickSelection {
    static func move(_ selected: UUID?, in results: [SavedRepository], offset: Int) -> UUID? {
        guard !results.isEmpty else { return nil }
        guard let selected, let index = results.firstIndex(where: { $0.id == selected }) else { return offset < 0 ? results.last?.id : results.first?.id }
        return results[min(max(index + offset, 0), results.count - 1)].id
    }
}
