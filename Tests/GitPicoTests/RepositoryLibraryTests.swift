import Foundation
import GitCore
import Testing
@testable import GitPico

@MainActor private struct LibraryFixture {
    let root: URL
    let library: RepositoryLibrary
    var file: URL { root.appendingPathComponent("library.json") }
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GitPico-library-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: [])
    }
    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test @MainActor func libraryPersistsBookmarksGroupsFavoritesAndNameAcrossRestart() throws {
    let f = try LibraryFixture(); defer { f.clean() }
    let group = try f.library.createGroup("Work"), child = try f.library.createGroup("Clients", parent: group)
    let url = try f.directory("Repo"), id = try f.library.register(url)
    try f.library.rename([id], to: "Custom Name"); try f.library.setFavorite([id], true); try f.library.move([id], to: child)
    let reopened = RepositoryLibrary(file: f.file, legacy: ["/unrelated/legacy"])
    #expect(reopened.error == nil && reopened.document == f.library.document)
    #expect(reopened.document.repositories.first?.name == "Custom Name")
    #expect(reopened.document.repositories.first?.favorite == true)
    #expect(reopened.breadcrumb(child) == "Work / Clients")
    #expect(reopened.matches(filter: .group(group)).map(\.id) == [id])
    #expect(reopened.recentPaths.isEmpty)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test @MainActor func libraryMigratesLegacyRecentsOnceAndKeepsAllBeyondTwelve() throws {
    let f = try LibraryFixture(); defer { f.clean() }
    let first = try f.directory("First"), second = try f.directory("Second")
    let library = RepositoryLibrary(file: f.file, legacy: [first.path, first.path, second.path])
    #expect(library.document.repositories.count == 2)
    #expect(library.recentPaths == [first.path, second.path])
    let id = try library.recordOpened(first)
    try library.rename([id], to: "Named")
    for number in 0..<15 { _ = try library.recordOpened(try f.directory("Repo-\(number)")) }
    #expect(library.recentPaths.count == 12 && library.document.repositories.count == 17)
    let reopened = RepositoryLibrary(file: f.file, legacy: ["/should/not/be/imported"])
    #expect(reopened.document == library.document)
    #expect(reopened.document.repositories.first { $0.id == id }?.name == "Named")
    try reopened.remove([id])
    let again = RepositoryLibrary(file: f.file, legacy: [first.path])
    #expect(!again.document.repositories.contains { $0.id == id })
    #expect(FileManager.default.fileExists(atPath: first.path))
}

@Test @MainActor func libraryCanonicalizesAliasesAndPreservesMetadataWhenReopened() throws {
    let f = try LibraryFixture(); defer { f.clean() }
    let source = try f.directory("Source"), alias = f.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
    let id = try f.library.recordOpened(source)
    try f.library.rename([id], to: "Display"); try f.library.setFavorite([id], true)
    #expect(try f.library.recordOpened(alias) == id)
    #expect(f.library.document.repositories.count == 1)
    #expect(f.library.document.repositories[0].name == "Display" && f.library.document.repositories[0].favorite)
    #expect(f.library.recentPaths == [source.path])
}

@Test @MainActor func libraryGroupCyclesAreRejectedAndRemovalKeepsContents() throws {
    let f = try LibraryFixture(); defer { f.clean() }
    let parent = try f.library.createGroup("Parent"), child = try f.library.createGroup("Child", parent: parent)
    let nested = try f.library.createGroup("Nested", parent: child), id = try f.library.register(f.directory("Repo"))
    try f.library.move([id], to: child)
    let before = try Data(contentsOf: f.file)
    #expect(throws: GitFailure.self) { try f.library.moveGroup(parent, parent: nested) }
    #expect(try Data(contentsOf: f.file) == before)
    #expect(throws: GitFailure.self) { try f.library.moveGroup(child, parent: child) }
    try f.library.removeGroup(child)
    #expect(f.library.document.repositories[0].group == parent)
    #expect(f.library.document.groups.first { $0.id == nested }?.parent == parent)
    let reopened = RepositoryLibrary(file: f.file, legacy: [])
    #expect(reopened.error == nil && reopened.document == f.library.document)
}

@Test @MainActor func libraryCrossInstanceEditsAndLockCannotOverwriteNewState() throws {
    let f = try LibraryFixture(); defer { f.clean() }
    let other = RepositoryLibrary(file: f.file, legacy: [])
    let id = try f.library.recordOpened(f.directory("Source")), data = try Data(contentsOf: f.file)
    #expect(throws: GitFailure.self) { try other.createGroup("Stale") }
    #expect(try Data(contentsOf: f.file) == data && other.document.groups.isEmpty)
    other.reload(); try other.rename([id], to: "Fresh")
    #expect(throws: GitFailure.self) { try f.library.rename([id], to: "Overwrite") }
    f.library.reload()
    let lock = URL(fileURLWithPath: f.file.path + ".lock")
    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
    #expect(throws: GitFailure.self) { try f.library.setFavorite([id], true) }
    #expect(FileManager.default.fileExists(atPath: lock.path))
    #expect(RepositoryLibrary(file: f.file, legacy: []).document.repositories[0].name == "Fresh")
}

@Test @MainActor func libraryCorruptFutureAndSymlinkStorageAreNeverReplaced() throws {
    let f = try LibraryFixture(); defer { f.clean() }
    for bytes in [Data("broken json".utf8), try JSONEncoder().encode(RepositoryLibraryDocument(version: 999))] {
        try bytes.write(to: f.file)
        let library = RepositoryLibrary(file: f.file, legacy: [])
        #expect(library.error != nil)
        #expect(throws: GitFailure.self) { try library.createGroup("No overwrite") }
        #expect(try Data(contentsOf: f.file) == bytes)
    }
    try FileManager.default.removeItem(at: f.file)
    let target = f.root.appendingPathComponent("real.json"), data = try JSONEncoder().encode(RepositoryLibraryDocument())
    try data.write(to: target); try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: target)
    let linked = RepositoryLibrary(file: f.file, legacy: [])
    #expect(linked.error != nil)
    #expect(throws: GitFailure.self) { try linked.createGroup("No links") }
    #expect(try Data(contentsOf: target) == data)
}

@Test @MainActor func librarySearchRankingKeyboardSelectionAndRecentOrdering() throws {
    let f = try LibraryFixture(); defer { f.clean() }
    let group = try f.library.createGroup("Clients")
    let alpha = try f.library.recordOpened(f.directory("Alpha")), beta = try f.library.recordOpened(f.directory("Beta"))
    try f.library.rename([alpha], to: "Café Alpha"); try f.library.move([alpha], to: group); try f.library.setFavorite([alpha], true)
    #expect(f.library.matches(query: "CAFE clients").map(\.id) == [alpha])
    #expect(f.library.matches(query: "beta", ranked: true).first?.id == beta)
    #expect(f.library.matches(ranked: true).first?.id == alpha)
    #expect(f.library.matches(filter: .recent).first?.id == beta)
    #expect(f.library.matches(query: f.root.lastPathComponent).count == 2)
    #expect(f.library.matches(query: "absent").isEmpty)
    let results = f.library.matches(ranked: true)
    #expect(RepositoryQuickSelection.move(nil, in: results, offset: 1) == alpha)
    #expect(RepositoryQuickSelection.move(alpha, in: results, offset: -1) == alpha)
    #expect(RepositoryQuickSelection.move(alpha, in: results, offset: 1) == beta)
    #expect(RepositoryQuickSelection.move(beta, in: results, offset: 1) == beta)
    #expect(RepositoryQuickSelection.move(beta, in: [], offset: 1) == nil)
}

@Test @MainActor func libraryMultiDropSortAndStaleSessionGuard() throws {
    let f = try LibraryFixture(); defer { f.clean() }
    let group = try f.library.createGroup("Group")
    let c = try f.library.register(f.directory("C")), a = try f.library.register(f.directory("A")), b = try f.library.register(f.directory("B"))
    let token = RepositoryLibraryDrop(session: f.library.session, repositories: [c, a])
    #expect(f.library.acceptDrop([token], to: group))
    #expect(Set(f.library.matches(filter: .group(group)).map(\.id)) == [c, a])
    try f.library.sortContents(of: group)
    #expect(f.library.matches(filter: .group(group)).map(\.id) == [a, c])
    #expect(f.library.acceptDrop([RepositoryLibraryDrop(session: f.library.session, repositories: [b])], to: group, before: c))
    #expect(f.library.matches(filter: .group(group)).map(\.id) == [a, b, c])
    let data = try Data(contentsOf: f.file)
    #expect(!f.library.acceptDrop([RepositoryLibraryDrop(session: UUID(), repositories: [a])], to: nil))
    #expect(!f.library.acceptDrop([RepositoryLibraryDrop(session: f.library.session, repositories: [a, UUID()])], to: nil))
    #expect(try Data(contentsOf: f.file) == data)
    f.library.reload()
    #expect(!f.library.acceptDrop([token], to: nil))
}

@Test @MainActor func libraryRelocateKeepsIdentityAndRejectsExistingRegistration() throws {
    let f = try LibraryFixture(); defer { f.clean() }
    let source = try f.directory("Source"), destination = f.root.appendingPathComponent("Moved")
    let id = try f.library.recordOpened(source)
    try f.library.rename([id], to: "My Repo"); try f.library.setFavorite([id], true)
    try FileManager.default.moveItem(at: source, to: destination)
    try f.library.relocate(id, to: destination)
    #expect(f.library.recentPaths == [destination.path])
    #expect(f.library.document.repositories[0].id == id && f.library.document.repositories[0].name == "My Repo")
    let other = try f.library.register(f.directory("Other"))
    #expect(throws: GitFailure.self) { try f.library.relocate(other, to: destination) }
    #expect(f.library.document.repositories.count == 2)
}

@Test @MainActor func libraryStoreOpensRealRepositoryAndRejectsStaleRelocation() async throws {
    let f = try LibraryFixture(); defer { f.clean() }
    let url = try f.directory("GitRepo")
    _ = try await GitProcess.run(["init", "-q", "-b", "main"], at: url)
    let store = RepositoryStore(library: f.library)
    await store.open(url)
    #expect(store.error == nil && store.snapshot != nil && !store.isBusy)
    #expect(store.recentPaths == [url.path])
    let entry = try #require(f.library.document.repositories.first)
    try f.library.rename([entry.id], to: "Renamed Display")
    await store.openSavedRepository(entry)
    #expect(store.error == nil && f.library.document.repositories.first?.name == "Renamed Display")
    let moved = try f.directory("OtherGitRepo")
    _ = try await GitProcess.run(["init", "-q", "-b", "main"], at: moved)
    try f.library.relocate(entry.id, to: moved)
    let head = try await store.repository?.headPosition()
    await store.openSavedRepository(entry)
    #expect(store.error?.contains("saved repository changed") == true)
    #expect(try await store.repository?.headPosition() == head)
    #expect(store.snapshot?.root.path == url.path)
    #expect(try await GitProcess.run(["status", "--porcelain"], at: url).data.isEmpty)
}

@Test @MainActor func libraryOpenSurvivesMetadataConflictWithoutLosingExistingLibrary() async throws {
    let f = try LibraryFixture(); defer { f.clean() }
    let url = try f.directory("GitRepo")
    _ = try await GitProcess.run(["init", "-q", "-b", "main"], at: url)
    let other = RepositoryLibrary(file: f.file, legacy: [])
    _ = try other.createGroup("External")
    let data = try Data(contentsOf: f.file), store = RepositoryStore(library: f.library)
    await store.open(url)
    #expect(store.snapshot?.root.path == url.path)
    #expect(store.error?.contains("Repository opened, but") == true)
    #expect(try Data(contentsOf: f.file) == data)
    #expect(!store.isBusy)
}

@Test @MainActor func libraryImportSanitizesDisplayNameButPreservesUnusualPath() throws {
    let f = try LibraryFixture(); defer { f.clean() }
    let path = try f.directory("中文\nrepo")
    let id = try f.library.register(path)
    #expect(f.library.document.repositories.first?.path == path.path)
    #expect(f.library.document.repositories.first?.name == "中文repo")
    #expect(throws: GitFailure.self) { try f.library.rename([id], to: "\n") }
    #expect(throws: GitFailure.self) { try f.library.rename([id], to: "invalid\nname") }
    #expect(RepositoryLibrary(file: f.file, legacy: []).document.repositories.first?.path == path.path)
}

@Test @MainActor func libraryMainMigrationRelocatesNestedEntriesAtomicallyAndPreservesMetadata() throws {
    let f = try LibraryFixture(); defer { f.clean() }
    let source = try f.directory("Source"), nested = try f.directory("Source/deps/lib"), sibling = try f.directory("Source-extra")
    let main = try f.library.recordOpened(source), child = try f.library.recordOpened(nested), other = try f.library.recordOpened(sibling)
    let group = try f.library.createGroup("Work")
    try f.library.rename([child], to: "Child Display"); try f.library.setFavorite([main, child], true); try f.library.move([child], to: group)
    let destination = f.root.appendingPathComponent("Moved")
    try f.library.relocatePrefix(from: source.path, to: destination.path)
    let reopened = RepositoryLibrary(file: f.file, legacy: [])
    #expect(reopened.document == f.library.document)
    #expect(reopened.document.repositories.first { $0.id == main }?.path == destination.path)
    let savedChild = try #require(reopened.document.repositories.first { $0.id == child })
    #expect(savedChild.path == destination.path + "/deps/lib" && savedChild.name == "Child Display" && savedChild.favorite && savedChild.group == group)
    #expect(reopened.document.repositories.first { $0.id == other }?.path == sibling.path)
    let collision = try f.library.register(f.directory("Collision/deps/lib")), bytes = try Data(contentsOf: f.file)
    #expect(throws: GitFailure.self) { try f.library.relocatePrefix(from: destination.path, to: f.root.appendingPathComponent("Collision").path) }
    #expect(try Data(contentsOf: f.file) == bytes && f.library.document.repositories.contains { $0.id == collision })
}
