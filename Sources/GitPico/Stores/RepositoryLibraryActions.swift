import AppKit
import GitCore

extension RepositoryTab {
    func addDroppedRepositories(_ urls: [URL]) -> Bool {
        guard acceptsRepositoryDrops, !urls.isEmpty else { return false }
        pickerDropWarning = nil
        store.isBusy = true
        store.activity = String(localized: "Checking repository…")
        store.operationTask = Task {
            defer { store.isBusy = false; store.activity = "" }
            var firstAdded: UUID?
            var rejected: [String] = []
            var storageError: String?
            var seen: Set<URL> = []
            for url in urls where url.isFileURL {
                let folder = url.standardizedFileURL.resolvingSymlinksInPath()
                guard seen.insert(folder).inserted else { continue }
                // Git also resolves subfolders to their parent repository. Import only the dropped root.
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let repository = try? await GitRepository.open(folder), await repository.root.path == folder.path else {
                    rejected.append(url.lastPathComponent)
                    continue
                }
                do {
                    let id = try store.library.register(folder)
                    firstAdded = firstAdded ?? id
                } catch {
                    storageError = error.localizedDescription
                    break
                }
            }
            if let firstAdded {
                pickerQuery = ""
                pickerFilter = .all
                pickerSelection = firstAdded
                pickerReveal = firstAdded
            }
            if let storageError {
                pickerDropWarning = storageError
            } else if !rejected.isEmpty {
                pickerDropWarning = String(localized: "Choose a Git working directory.") + " " + rejected.formatted(.list(type: .and))
            }
        }
        return true
    }
}

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
        let state = await library.refreshFolderState(for: current)
        guard library.document.repositories.contains(where: { $0.id == current.id && $0.path == current.path }) else {
            error = String(localized: "The saved repository changed. Refresh the repository list.")
            return
        }
        guard state.canOpen else {
            error = (state.warning ?? "") + " · " + String(localized: "Locate Repository…")
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
