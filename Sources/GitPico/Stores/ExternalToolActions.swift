import AppKit
import Foundation
import GitCore
import Observation

struct ExternalToolSettings: Codable, Equatable {
    var version = 1
    var diff = ExternalToolCommand(executable: "/usr/bin/opendiff", arguments: ["{local}", "{remote}"])
    var merge = ExternalToolCommand(executable: "/usr/bin/opendiff", arguments: ["{local}", "{remote}", "-ancestor", "{base}", "-merge", "{merged}"])
    var terminalAppPath: String?
    var editorAppPath: String?

    enum CodingKeys: String, CodingKey {
        case version, diff, merge, terminalAppPath, editorAppPath
    }

    init(
        version: Int = 1,
        diff: ExternalToolCommand = ExternalToolCommand(executable: "/usr/bin/opendiff", arguments: ["{local}", "{remote}"]),
        merge: ExternalToolCommand = ExternalToolCommand(executable: "/usr/bin/opendiff", arguments: ["{local}", "{remote}", "-ancestor", "{base}", "-merge", "{merged}"]),
        terminalAppPath: String? = nil,
        editorAppPath: String? = nil
    ) {
        self.version = version
        self.diff = diff
        self.merge = merge
        self.terminalAppPath = Self.normalizedAppPath(terminalAppPath)
        self.editorAppPath = Self.normalizedAppPath(editorAppPath)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        diff = try container.decode(ExternalToolCommand.self, forKey: .diff)
        merge = try container.decode(ExternalToolCommand.self, forKey: .merge)
        terminalAppPath = Self.normalizedAppPath(try container.decodeIfPresent(String.self, forKey: .terminalAppPath))
        editorAppPath = Self.normalizedAppPath(try container.decodeIfPresent(String.self, forKey: .editorAppPath))
    }

    static func normalizedAppPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
@MainActor @Observable final class ExternalToolPreferences {
    private(set) var value = ExternalToolSettings()
    private(set) var error: String?
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var original: Data?
    @ObservationIgnored private var valid = true
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GitPico/external-tools.json")
        reload()
    }
    func reload() {
        do {
            let data = try read(); let value = try data.map { try JSONDecoder().decode(ExternalToolSettings.self, from: $0) } ?? ExternalToolSettings()
            try validate(value); self.value = value; original = data; valid = true; error = nil
        } catch { self.error = error.localizedDescription; valid = false }
    }
    private func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 256 * 1024 else { throw appFailure("External tool settings must be a regular file under 256 KB.") }
        return try Data(contentsOf: file)
    }
    private func validate(_ value: ExternalToolSettings) throws {
        guard value.version == 1 else { throw appFailure("Unsupported external tool settings version.") }
        let files = Dictionary(uniqueKeysWithValues: ["local", "remote", "base", "merged"].map { ($0, URL(fileURLWithPath: "/tmp/" + $0)) })
        _ = try value.diff.invocation(files: files, merge: false); _ = try value.merge.invocation(files: files, merge: true)
        for path in [value.terminalAppPath, value.editorAppPath].compactMap({ $0 }) {
            guard path.hasPrefix("/"), !path.contains("\0") else {
                throw appFailure("External application paths must be absolute paths.")
            }
        }
    }
    func save(_ value: ExternalToolSettings, expected: ExternalToolSettings? = nil) throws {
        do {
            guard valid else { throw appFailure("Reload valid tool settings before saving. The existing file was kept.") }
            if let expected, expected != self.value { throw appFailure("Tool settings changed while this editor was open. Reload before saving.") }
            try validate(value)
            guard try read() == original else { throw appFailure("External tool settings changed outside this window. Reload before saving.") }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value); try data.write(to: file, options: .atomic)
            self.value = value; original = data; error = nil
        } catch { self.error = error.localizedDescription; throw error }
    }
}

enum ExternalToolAction { case working(String, Bool), comparison(String?, String, String, String?), merge(String), sessions }
struct ExternalToolRequest: Identifiable { let id = UUID(); let repositoryToken: UUID; let action: ExternalToolAction }

extension RepositoryStore {
    var resolvedDefaultTerminal: ResolvedExternalApp {
        ExternalAppCatalog.shared.resolve(kind: .terminal, settings: toolPreferences.value)
    }
    var resolvedDefaultEditor: ResolvedExternalApp {
        ExternalAppCatalog.shared.resolve(kind: .editor, settings: toolPreferences.value)
    }
    func openInTerminal(_ app: InstalledExternalApp? = nil, catalog: ExternalAppCatalog = .shared) {
        guard canInspectRepository, let root = snapshot?.root else { return }
        openDirectory(root, kind: .terminal, explicitApp: app, catalog: catalog)
    }
    func openInEditor(_ app: InstalledExternalApp? = nil, catalog: ExternalAppCatalog = .shared) {
        guard canInspectRepository, let root = snapshot?.root else { return }
        openDirectory(root, kind: .editor, explicitApp: app, catalog: catalog)
    }
    func revealRepositoryInFinder() {
        guard canInspectRepository, let root = snapshot?.root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }
    func copyRepositoryPath() {
        guard canInspectRepository, let root = snapshot?.root else { return }
        Pico.copy(root.path)
    }
    private func openDirectory(_ directory: URL, kind: ExternalAppKind, explicitApp: InstalledExternalApp?, catalog: ExternalAppCatalog) {
        let target: InstalledExternalApp
        if let explicitApp {
            target = explicitApp
        } else {
            switch catalog.resolve(kind: kind, settings: toolPreferences.value) {
            case .configured(let app), .automatic(let app):
                target = app
            case .missingConfigured(let path):
                error = String(localized: "The configured application could not be found at \(path). Choose another app in Settings → External Tools.")
                return
            case .unavailable:
                error = kind == .terminal
                    ? String(localized: "No terminal application was found. Choose one in Settings → External Tools.")
                    : String(localized: "No editor application was found. Choose one in Settings → External Tools.")
                return
            }
        }
        Task { @MainActor [weak self] in
            do { try await catalog.open(directory: directory, in: target) }
            catch { self?.error = error.localizedDescription }
        }
    }
    func externalTool(_ action: ExternalToolAction) {
        guard !isBusy, repository != nil else { return }
        externalToolRequest = ExternalToolRequest(repositoryToken: repositoryToken, action: action)
    }
    func applyExternalResult(_ id: UUID, expectedResult: Data? = nil, request: ExternalToolRequest) {
        guard request.repositoryToken == repositoryToken else { error = String(localized: "The repository changed. Reopen the tool session."); return }
        let runner = externalToolRunner
        perform("Applying external merge result…") {
            guard await runner.status(id).running == false else { throw appFailure("Close the merge tool before applying its result.") }
            try await $0.applyExternalMerge(id, expectedResult: expectedResult)
        }
    }
    func refreshFileBrowser() async {
        guard let repository else { return }
        let token = repositoryToken, generation = UUID(); fileBrowserGeneration = generation
        let ignored = showIgnoredFiles
        do {
            let files = try await repository.workingFiles(includeIgnored: ignored)
            guard token == repositoryToken, generation == fileBrowserGeneration, !Task.isCancelled else { return }
            workingFileEntries = files
            await rebuildWorkingList()
        } catch { if token == repositoryToken && generation == fileBrowserGeneration && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    var visibleWorkingFiles: [WorkingFileEntry] { WorkingFilesPresentation.visible(workingFilesInput) }
}
