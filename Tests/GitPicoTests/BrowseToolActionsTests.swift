import Foundation
import GitCore
import Testing
@testable import GitPico

@MainActor private struct BrowseAppFixture {
    let root: URL
    let repository: GitRepository
    let store: RepositoryStore
    static func make() async throws -> BrowseAppFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-browse-app-\(UUID())")
        let url = root.appendingPathComponent("Repo")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await GitProcess.run(["init", "-q", "-b", "main"], at: url)
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await GitProcess.run(["config", key, value], at: url) }
        try Data("original\n".utf8).write(to: url.appendingPathComponent("readme"))
        _ = try await GitProcess.run(["add", "."], at: url); _ = try await GitProcess.run(["commit", "-qm", "Initial"], at: url)
        let repository = try await GitRepository.open(url), store = RepositoryStore(library: RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: []))
        store.toolPreferences = ExternalToolPreferences(file: root.appendingPathComponent("tools.json"))
        store.repository = repository; store.snapshot = try await repository.snapshot()
        return BrowseAppFixture(root: root, repository: repository, store: store)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test @MainActor func browseStoreSeparatesCleanIgnoredAndChangedFilesWithoutFakeStaging() async throws {
    let f = try await BrowseAppFixture.make(); defer { f.clean() }
    let root = await f.repository.root
    try Data("*.log\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
    try Data("ignored\n".utf8).write(to: root.appendingPathComponent("private.log"))
    f.store.snapshot = try await f.repository.snapshot()
    #expect(!f.store.visibleWorkingFiles.contains { $0.path == "readme" })
    f.store.showAllFiles = true; await f.store.refreshFileBrowser()
    #expect(f.store.visibleWorkingFiles.contains { $0.path == "readme" && $0.change == nil })
    #expect(!f.store.visibleWorkingFiles.contains { $0.isIgnored })
    f.store.showIgnoredFiles = true; await f.store.refreshFileBrowser()
    #expect(f.store.visibleWorkingFiles.contains { $0.path == "private.log" && $0.isIgnored && $0.change == nil })
    #expect(!f.store.unstaged.contains { $0.path == "private.log" })
    let clean = try #require(f.store.visibleWorkingFiles.first { $0.path == "readme" })
    f.store.selectBrowserFile(clean)
    #expect(f.store.selectedChange == "readme" && f.store.currentChange == nil && f.store.diff.isEmpty)
    _ = try await GitProcess.run(["update-index", "--assume-unchanged", "readme"], at: root)
    f.store.showAllFiles = false; f.store.showIgnoredFiles = false; f.store.showAssumeUnchanged = true
    await f.store.refreshFileBrowser()
    #expect(f.store.visibleWorkingFiles.contains { $0.path == "readme" && $0.assumeUnchanged })
}

@Test @MainActor func quickActionsExposeContextSearchAndKeepDangerousActionsReviewed() async throws {
    let f = try await BrowseAppFixture.make(); defer { f.clean() }
    let root = await f.repository.root
    try Data("edited\n".utf8).write(to: root.appendingPathComponent("readme"))
    f.store.snapshot = try await f.repository.snapshot()
    let files = try await f.repository.workingFiles(), items = f.store.quickActionItems(files: files)
    #expect(items.contains { $0.id == "command:Create Branch" })
    #expect(items.contains { $0.id == "command:Discard All Local Changes" })
    #expect(QuickActionSearch.results(items, query: "file history readme").contains { $0.id == "file-history:readme" })
    let discard = try #require(items.first { $0.id == "command:Discard All Local Changes" })
    f.store.runQuickAction(discard, repositoryToken: f.store.repositoryToken)
    guard case .discard(let paths) = f.store.localChangeRequest?.action else { Issue.record("Expected a discard review"); return }
    #expect(paths == ["readme"])
    #expect(try Data(contentsOf: root.appendingPathComponent("readme")) == Data("edited\n".utf8))
    #expect(try await GitProcess.run(["show", ":readme"], at: root).text == "original\n")
    f.store.localChangeRequest = nil
    f.store.runQuickAction(discard, repositoryToken: UUID())
    #expect(f.store.localChangeRequest == nil && f.store.error?.contains("repository changed") == true)
    let index = QuickActionSearch.move(nil, in: items, offset: 1)
    #expect(index == items.first?.id)
    #expect(QuickActionSearch.move(items.last?.id, in: items, offset: 1) == items.last?.id)
}

@Test @MainActor func quickActionCanSelectCleanFileWithAllFilesEnabled() async throws {
    let f = try await BrowseAppFixture.make(); defer { f.clean() }
    let items = f.store.quickActionItems(files: try await f.repository.workingFiles())
    let item = try #require(items.first { $0.id == "file:readme" })
    f.store.search = "other file"
    f.store.runQuickAction(item, repositoryToken: f.store.repositoryToken)
    let deadline = Date().addingTimeInterval(5)
    while f.store.selectedChange != "readme" && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(f.store.showAllFiles && f.store.search.isEmpty && f.store.selectedChange == "readme")
    #expect(f.store.currentChange == nil)
}

@Test @MainActor func toolPreferencesPersistAndRejectStaleInvalidAndCorruptEdits() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-tool-prefs-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("settings.json"), a = ExternalToolPreferences(file: file), b = ExternalToolPreferences(file: file)
    var value = a.value; value.diff.executable = "/usr/bin/true"
    let initial = a.value
    try a.save(value, expected: initial)
    #expect(ExternalToolPreferences(file: file).value == value)
    #expect(throws: GitFailure.self) { try a.save(initial, expected: initial) }
    #expect(throws: GitFailure.self) { try b.save(initial) }
    let data = try Data(contentsOf: file)
    var invalid = value; invalid.merge.arguments = ["{local}", "{remote}"]
    #expect(throws: GitFailure.self) { try a.save(invalid) }
    #expect(try Data(contentsOf: file) == data)
    try Data("broken".utf8).write(to: file)
    a.reload()
    #expect(a.error != nil)
    #expect(throws: GitFailure.self) { try a.save(value) }
    #expect(try Data(contentsOf: file) == Data("broken".utf8))
}
