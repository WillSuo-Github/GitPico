import Foundation
import Testing
@testable import GitCore

private func addTestModule(_ parent: Fixture, source: Fixture, path: String = "deps/lib [x]", name: String = "library") async throws -> ManagedSubmodule {
    try await parent.repo.addSubmodule(source: source.url.path, path: path, name: name, allowLocalTransport: true, expectedHead: parent.repo.headPosition(), expectedIndex: parent.repo.submoduleAddIndex())
    try await parent.git(["commit", "-m", "Add module"])
    return try #require(try await parent.repo.managedSubmodules().first { $0.path == path })
}

@Test func submoduleAddListDeinitializeAndInitializeKeepGitData() async throws {
    let parent = try await Fixture.make(), source = try await Fixture.make(); defer { parent.clean(); source.clean() }
    let module = try await addTestModule(parent, source: source)
    #expect(module.initialized && !module.dirty && module.head == module.recordedHash && module.name == "library")
    let child = try await parent.repo.checkedSubmodule(module)
    #expect(try await child.headPosition().hash == module.head)
    try await parent.repo.applySubmodule(try await parent.repo.previewSubmodule(module, operation: .deinitialize))
    let deinitialized = try #require(try await parent.repo.managedSubmodules().first)
    #expect(!deinitialized.initialized)
    #expect(FileManager.default.fileExists(atPath: module.gitDirectory!))
    try await parent.repo.applySubmodule(try await parent.repo.previewSubmodule(deinitialized, operation: .initialize, allowLocalTransport: true))
    #expect(try await parent.repo.managedSubmodules().first?.head == module.head)
}

@Test func submoduleMoveURLSyncRepairAndRemoveStageMetadataSafely() async throws {
    let parent = try await Fixture.make(), source = try await Fixture.make(); defer { parent.clean(); source.clean() }
    var module = try await addTestModule(parent, source: source)
    try await parent.repo.applySubmodule(try await parent.repo.previewSubmodule(module, operation: .move, value: "other/lib 中文"))
    module = try #require(try await parent.repo.managedSubmodules().first)
    #expect(module.path == "other/lib 中文" && module.initialized && module.head == module.recordedHash)
    try await parent.git(["commit", "-m", "Move module"])
    module = try #require(try await parent.repo.managedSubmodules().first)
    let marker = parent.url.appendingPathComponent(module.path + "/.git")
    try FileManager.default.removeItem(at: marker)
    let broken = try #require(try await parent.repo.managedSubmodules().first)
    try await parent.repo.applySubmodule(try await parent.repo.previewSubmodule(broken, operation: .repair))
    module = try #require(try await parent.repo.managedSubmodules().first)
    #expect(module.initialized && module.head != nil)
    try await parent.repo.applySubmodule(try await parent.repo.previewSubmodule(module, operation: .setURL, value: source.url.path, allowLocalTransport: true))
    module = try #require(try await parent.repo.managedSubmodules().first)
    try await parent.repo.applySubmodule(try await parent.repo.previewSubmodule(module, operation: .sync, recursive: true))
    module = try #require(try await parent.repo.managedSubmodules().first)
    let admin = try #require(module.gitDirectory)
    try await parent.repo.applySubmodule(try await parent.repo.previewSubmodule(module, operation: .remove))
    #expect(try await parent.repo.managedSubmodules().isEmpty)
    #expect(FileManager.default.fileExists(atPath: admin))
    #expect(try await parent.git(["ls-files", "--stage"]).text.contains("160000") == false)
}

@Test func submoduleDirtyAndChangedPreviewCannotOverwriteLocalFiles() async throws {
    let parent = try await Fixture.make(), source = try await Fixture.make(); defer { parent.clean(); source.clean() }
    let module = try await addTestModule(parent, source: source)
    let plan = try await parent.repo.previewSubmodule(module, operation: .update, allowLocalTransport: true)
    try Data("local edit\n".utf8).write(to: parent.url.appendingPathComponent(module.path + "/readme.txt"))
    await #expect(throws: GitFailure.self) { try await parent.repo.applySubmodule(plan) }
    let dirty = try #require(try await parent.repo.managedSubmodules().first)
    #expect(dirty.dirty)
    await #expect(throws: GitFailure.self) { try await parent.repo.previewSubmodule(dirty, operation: .remove) }
    #expect(try String(contentsOf: parent.url.appendingPathComponent(module.path + "/readme.txt"), encoding: .utf8) == "local edit\n")
}

@Test func submoduleFetchCheckoutAndPinnedUpdateDoNotCommitParent() async throws {
    let parent = try await Fixture.make(), source = try await Fixture.make(); defer { parent.clean(); source.clean() }
    let module = try await addTestModule(parent, source: source), original = try #require(module.head)
    let parentHead = try await parent.repo.headPosition()
    try source.write("readme.txt", "next\n"); try await source.git(["add", "."]); try await source.git(["commit", "-m", "Next"])
    let next = try #require(try await source.repo.headPosition().hash)
    try await parent.repo.applySubmodule(try await parent.repo.previewSubmodule(module, operation: .fetch, allowLocalTransport: true))
    var current = try #require(try await parent.repo.managedSubmodules().first)
    try await parent.repo.applySubmodule(try await parent.repo.previewSubmodule(current, operation: .checkout, value: next))
    current = try #require(try await parent.repo.managedSubmodules().first)
    #expect(current.head == next && current.recordedHash == original)
    await #expect(throws: GitFailure.self) { try await parent.repo.previewSubmodule(current, operation: .deinitialize) }
    try await parent.repo.applySubmodule(try await parent.repo.previewSubmodule(current, operation: .update, allowLocalTransport: true))
    #expect(try await parent.repo.managedSubmodules().first?.head == original)
    #expect(try await parent.repo.headPosition() == parentHead)
}

@Test func submoduleAdditionRejectsStaleParentAndUnsafeTransportsAndPaths() async throws {
    let parent = try await Fixture.make(), source = try await Fixture.make(); defer { parent.clean(); source.clean() }
    await #expect(throws: GitFailure.self) { try await parent.repo.previewSubmoduleAddition(source: source.url.path, path: "deps/library") }
    await #expect(throws: GitFailure.self) { try await parent.repo.previewSubmoduleAddition(source: "ext::false", path: "deps/library") }
    await #expect(throws: GitFailure.self) { try await parent.repo.previewSubmoduleAddition(source: source.url.path, path: "../escape", allowLocalTransport: true) }
    let relative = try await parent.repo.previewSubmoduleAddition(source: "../library.git", path: "relative-library")
    #expect(!relative.allowLocalTransport)
    let plan = try await parent.repo.previewSubmoduleAddition(source: source.url.path, path: "deps/library", allowLocalTransport: true)
    try parent.write("another", "staged\n"); try await parent.git(["add", "another"])
    await #expect(throws: GitFailure.self) { try await parent.repo.addSubmodule(plan) }
    #expect(!FileManager.default.fileExists(atPath: parent.url.appendingPathComponent("deps/library").path))
    let fresh = try await parent.repo.previewSubmoduleAddition(source: source.url.path, path: "deps/library", allowLocalTransport: true)
    try await parent.repo.addSubmodule(fresh)
    #expect(try await parent.repo.managedSubmodules().first?.initialized == true)
    #expect(try await parent.git(["diff", "--cached", "--name-only"]).text.contains("another"))
}

@Test func submoduleIgnoredFilesAndChangedGitmodulesBlockDestructiveActions() async throws {
    let parent = try await Fixture.make(), source = try await Fixture.make(); defer { parent.clean(); source.clean() }
    try source.write(".gitignore", "*.cache\n"); try await source.git(["add", "."]); try await source.git(["commit", "-m", "Ignore cache"])
    let module = try await addTestModule(parent, source: source)
    let plan = try await parent.repo.previewSubmodule(module, operation: .remove)
    let ignored = parent.url.appendingPathComponent(module.path + "/local.cache")
    try Data("preserve".utf8).write(to: ignored)
    await #expect(throws: GitFailure.self) { try await parent.repo.applySubmodule(plan) }
    var fresh = try #require(try await parent.repo.managedSubmodules().first)
    #expect(fresh.dirty)
    await #expect(throws: GitFailure.self) { try await parent.repo.previewSubmodule(fresh, operation: .deinitialize) }
    try FileManager.default.removeItem(at: ignored)
    fresh = try #require(try await parent.repo.managedSubmodules().first)
    let before = try Data(contentsOf: parent.url.appendingPathComponent(".gitmodules"))
    try (before + Data("\n# manual edit\n".utf8)).write(to: parent.url.appendingPathComponent(".gitmodules"))
    await #expect(throws: GitFailure.self) { try await parent.repo.applySubmodule(plan) }
    await #expect(throws: GitFailure.self) { try await parent.repo.previewSubmodule(fresh, operation: .setURL, value: "https://example.invalid/repo.git") }
}

@Test func submoduleRecursiveCloneAndNestedDirtyGuardsKeepLocalData() async throws {
    let leaf = try await Fixture.make(), middle = try await Fixture.make(), parent = try await Fixture.make()
    let clone = URL(fileURLWithPath: parent.url.path + "-clone")
    defer { leaf.clean(); middle.clean(); parent.clean(); try? FileManager.default.removeItem(at: clone) }
    _ = try await addTestModule(middle, source: leaf, path: "nested/leaf", name: "leaf")
    _ = try await addTestModule(parent, source: middle, path: "modules/middle", name: "middle")
    let cloned = try await GitRepository.create(at: clone, source: parent.url.path, recursive: true, allowLocalTransport: true)
    let outer = try #require(try await cloned.managedSubmodules().first)
    let child = try await cloned.checkedSubmodule(outer)
    let inner = try #require(try await child.managedSubmodules().first)
    #expect(inner.initialized && inner.head == inner.recordedHash)
    let plan = try await cloned.previewSubmodule(outer, operation: .update, recursive: true, allowLocalTransport: true)
    let local = clone.appendingPathComponent("modules/middle/nested/leaf/readme.txt")
    try Data("nested local edit\n".utf8).write(to: local)
    await #expect(throws: GitFailure.self) { try await cloned.applySubmodule(plan) }
    let fresh = try #require(try await cloned.managedSubmodules().first)
    await #expect(throws: GitFailure.self) { try await cloned.previewSubmodule(fresh, operation: .deinitialize) }
    #expect(try Data(contentsOf: local) == Data("nested local edit\n".utf8))
}

@Test func submoduleManagementUsesLinkedWorktreeGitStorage() async throws {
    let parent = try await Fixture.make(), source = try await Fixture.make()
    let linkedPath = URL(fileURLWithPath: parent.url.path + "-linked-modules")
    defer { parent.clean(); source.clean(); try? FileManager.default.removeItem(at: linkedPath) }
    _ = try await addTestModule(parent, source: source)
    let linked = try await parent.repo.checkedWorktree(try await parent.repo.createWorktree(try await parent.repo.previewWorktreeCreation(destination: linkedPath, mode: .detached)))
    var module = try #require(try await linked.managedSubmodules().first)
    #expect(!module.initialized)
    try await linked.applySubmodule(try await linked.previewSubmodule(module, operation: .initialize, allowLocalTransport: true))
    module = try #require(try await linked.managedSubmodules().first)
    let admin = try #require(module.gitDirectory)
    #expect(admin.contains("/worktrees/"))
    try FileManager.default.removeItem(at: linkedPath.appendingPathComponent(module.path + "/.git"))
    let broken = try #require(try await linked.managedSubmodules().first)
    try await linked.applySubmodule(try await linked.previewSubmodule(broken, operation: .repair))
    module = try #require(try await linked.managedSubmodules().first)
    try await linked.applySubmodule(try await linked.previewSubmodule(module, operation: .deinitialize))
    module = try #require(try await linked.managedSubmodules().first)
    try await linked.applySubmodule(try await linked.previewSubmodule(module, operation: .initialize, allowLocalTransport: true))
    module = try #require(try await linked.managedSubmodules().first)
    try await linked.applySubmodule(try await linked.previewSubmodule(module, operation: .remove))
    #expect(try await linked.managedSubmodules().isEmpty)
    #expect(FileManager.default.fileExists(atPath: admin))
    #expect(try await parent.repo.managedSubmodules().first?.initialized == true)
}
