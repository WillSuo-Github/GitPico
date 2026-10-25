import Foundation
import Testing
@testable import GitCore

private func infrastructureModule(_ parent: Fixture, _ source: Fixture, path: String = "deps/lib", name: String = "lib") async throws -> ManagedSubmodule {
    try await parent.repo.addSubmodule(try await parent.repo.previewSubmoduleAddition(source: source.url.path, path: path, name: name, allowLocalTransport: true))
    try await parent.git(["commit", "-m", "Register module"])
    return try #require(try await parent.repo.managedSubmodules().first { $0.name == name })
}
private func cleanMigration(_ plan: MainRepositoryMigrationPlan) {
    try? FileManager.default.removeItem(at: plan.destination)
    try? FileManager.default.removeItem(at: plan.destination.deletingLastPathComponent().appendingPathComponent(".gitpico-migrations/" + plan.id.uuidString))
}

@Test func mainRepositoryMigrationReconnectsLinkedAndNestedTreesAndRestoresDirtyState() async throws {
    let f = try await Fixture.make(), middle = try await Fixture.make(), leaf = try await Fixture.make()
    let moved = URL(fileURLWithPath: f.url.path + "-moved"), linked = URL(fileURLWithPath: f.url.path + "-linked")
    defer { f.clean(); middle.clean(); leaf.clean(); try? FileManager.default.removeItem(at: moved); try? FileManager.default.removeItem(at: linked) }
    _ = try await infrastructureModule(middle, leaf)
    let outer = try await infrastructureModule(f, middle)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(outer, operation: .initialize, recursive: true, allowLocalTransport: true))
    let link = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: linked, mode: .new, branch: "linked"))
    let linkRepo = try await f.repo.checkedWorktree(link), module = try #require(try await linkRepo.managedSubmodules().first)
    try await linkRepo.applySubmodule(try await linkRepo.previewSubmodule(module, operation: .initialize, recursive: true, allowLocalTransport: true))
    try f.write("readme.txt", "staged\n"); try await f.git(["add", "readme.txt"]); try f.write("readme.txt", "unstaged\n")
    try f.write("untracked", "keep\n")
    let index = try await f.repo.submoduleAddIndex()
    let plan = try await f.repo.previewMainRepositoryMigration(to: moved); defer { cleanMigration(plan) }
    let migrated = try await f.repo.migrateMainRepository(plan)
    #expect(!FileManager.default.fileExists(atPath: f.url.path))
    #expect(try await migrated.submoduleAddIndex() == index)
    #expect(try String(contentsOf: moved.appendingPathComponent("readme.txt"), encoding: .utf8) == "unstaged\n")
    let current = try #require(try await migrated.managedSubmodules().first)
    let child = try await migrated.checkedSubmodule(current)
    #expect(try await child.managedSubmodules().first?.initialized == true)
    let linkAfter = try #require(try await migrated.managedWorktrees().first { !$0.isMain })
    let reopenedLink = try await migrated.checkedWorktree(linkAfter)
    #expect(try await reopenedLink.managedSubmodules().first?.initialized == true)
    let journal = try #require(try await migrated.mainRepositoryMigrations().first)
    let restored = try await migrated.restoreMainRepositoryMigration(try await migrated.previewMainMigrationRestore(journal))
    #expect(try await restored.submoduleAddIndex() == index)
    #expect(try String(contentsOf: f.url.appendingPathComponent("untracked"), encoding: .utf8) == "keep\n")
    _ = try await restored.checkedWorktree(try #require(try await restored.managedWorktrees().first { !$0.isMain }))
}

@Test func mainMigrationRejectsStaleSourceAndRestorationCannotOverwriteNewEdits() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let moved = URL(fileURLWithPath: f.url.path + "-moved")
    let stale = try await f.repo.previewMainRepositoryMigration(to: moved); defer { cleanMigration(stale) }
    try f.write("new", "new edit")
    await #expect(throws: GitFailure.self) { try await f.repo.migrateMainRepository(stale) }
    #expect(FileManager.default.fileExists(atPath: f.url.path))
    let fresh = try await f.repo.previewMainRepositoryMigration(to: moved); defer { cleanMigration(fresh) }
    let migrated = try await f.repo.migrateMainRepository(fresh)
    let journal = try #require(try await migrated.mainRepositoryMigrations().first)
    let plan = try await migrated.previewMainMigrationRestore(journal)
    try Data("later".utf8).write(to: moved.appendingPathComponent("later"))
    await #expect(throws: GitFailure.self) { try await migrated.restoreMainRepositoryMigration(plan) }
    #expect(try String(contentsOf: moved.appendingPathComponent("later"), encoding: .utf8) == "later")
}

@Test func pointerRepairAfterExternalMainMoveAndLinkedMovePreservesData() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make()
    let moved = URL(fileURLWithPath: f.url.path + "-manual"), linked = URL(fileURLWithPath: f.url.path + "-linked"), relocated = URL(fileURLWithPath: f.url.path + "-relocated")
    defer { f.clean(); source.clean(); for url in [moved, linked, relocated] { try? FileManager.default.removeItem(at: url) } }
    _ = try await infrastructureModule(f, source)
    let entry = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: linked, mode: .detached))
    let admin = try await f.repo.worktreeAdministration(entry), id = admin.lastPathComponent
    try await f.git(["config", "extensions.worktreeConfig", "true"])
    try await f.git(["config", "--worktree", "core.worktree", f.url.path])
    try FileManager.default.moveItem(at: f.url, to: moved)
    try FileManager.default.moveItem(at: linked, to: relocated)
    let raw = GitRepository(root: moved.resolvingSymlinksInPath())
    let plan = try await raw.previewPointerRepair(previousMainPath: f.url.path, locations: ["worktree:" + id: relocated.path], replaceBrokenMarkers: true)
    #expect(plan.targets.contains { $0.id == "worktree:" + id && !$0.missing })
    _ = try await raw.applyPointerRepair(plan)
    let opened = try await GitRepository.open(moved)
    #expect(try await opened.managedSubmodules().first?.initialized == true)
    let linkedRepo = try await opened.checkedWorktree(try #require(try await opened.managedWorktrees().first { !$0.isMain }))
    #expect(try await linkedRepo.headPosition().hash == entry.head)
    #expect(try String(contentsOf: relocated.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\n")
}

@Test func pointerRepairRelocatedModuleStagesMappingAndSupportsUndoAndStaleGuard() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make(); defer { f.clean(); source.clean() }
    let module = try await infrastructureModule(f, source)
    let destination = f.url.appendingPathComponent("relocated/lib")
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: f.url.appendingPathComponent(module.path), to: destination)
    let plan = try await f.repo.previewPointerRepair(locations: ["module:main/lib": destination.path], replaceBrokenMarkers: true)
    let record = try await f.repo.applyPointerRepair(plan)
    let repaired = try #require(try await f.repo.managedSubmodules().first)
    #expect(repaired.path == "relocated/lib" && repaired.initialized && repaired.head == module.head)
    #expect(try await f.git(["diff", "--cached", "--name-only"]).text.contains(".gitmodules"))
    await #expect(throws: GitFailure.self) { try await f.repo.applyPointerRepair(plan) }
    try await f.repo.resumePointerRepair(record, undo: true)
    #expect(try await f.repo.managedSubmodules().first?.path == module.path)
}

@Test func submoduleDirectoryReusePreservesExistingFilesAndRetainedIndexWithoutFetch() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make(); defer { f.clean(); source.clean() }
    let existingPath = f.url.appendingPathComponent("existing")
    _ = try await GitRepository.create(at: existingPath, source: source.url.path)
    try Data("local edit".utf8).write(to: existingPath.appendingPathComponent("readme.txt"))
    let existing = try await f.repo.previewSubmoduleAddition(source: source.url.path, path: "existing", name: "existing", allowLocalTransport: true, directoryMode: .existingRepository)
    try await f.repo.addSubmodule(existing)
    #expect(try String(contentsOf: existingPath.appendingPathComponent("readme.txt"), encoding: .utf8) == "local edit")
    let module = try await infrastructureModule(f, source)
    let moduleRoot = f.url.appendingPathComponent(module.path)
    try Data("staged child".utf8).write(to: moduleRoot.appendingPathComponent("readme.txt"))
    _ = try await GitProcess.run(["add", "readme.txt"], at: moduleRoot)
    let dirty = try #require(try await f.repo.managedSubmodules().first { $0.name == module.name })
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(dirty, operation: .forceRemove))
    try await f.git(["commit", "-m", "Remove module"])
    let reused = try await f.repo.previewSubmoduleAddition(source: source.url.path, path: "new/lib", name: module.name, allowLocalTransport: true, directoryMode: .retainedRepository)
    try await f.repo.addSubmodule(reused)
    #expect(try String(contentsOf: f.url.appendingPathComponent("new/lib/readme.txt"), encoding: .utf8) == "staged child")
    #expect(try await f.repo.managedSubmodules().first { $0.name == module.name }?.dirty == true)
}

@Test func forcedWorktreeRemovalPreservesIgnoredUntrackedAndConflictedIndexInBackup() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let path = URL(fileURLWithPath: f.url.path + "-force"); defer { try? FileManager.default.removeItem(at: path) }
    let entry = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: path, mode: .new, branch: "force"))
    try Data("ignored\n".utf8).write(to: path.appendingPathComponent(".gitignore"))
    try Data("keep ignored".utf8).write(to: path.appendingPathComponent("ignored"))
    try Data("keep untracked".utf8).write(to: path.appendingPathComponent("untracked"))
    try await f.repo.setWorktreeLocked(entry, locked: true, reason: "Keep lock")
    let locked = try #require(try await f.repo.managedWorktrees().first { !$0.isMain })
    await #expect(throws: GitFailure.self) { try await f.repo.removeWorktree(locked, force: true) }
    try await f.repo.removeWorktree(locked, force: true, unlock: true)
    let backup = try #require(try await f.repo.relatedManagementBackups().first)
    try await f.repo.restoreRelatedManagement(try await f.repo.previewRelatedManagementRestore(backup))
    #expect(try String(contentsOf: path.appendingPathComponent("ignored"), encoding: .utf8) == "keep ignored")
    #expect(try String(contentsOf: path.appendingPathComponent("untracked"), encoding: .utf8) == "keep untracked")
    #expect(try await f.repo.managedWorktrees().first { !$0.isMain }?.locked == "Keep lock")
}

@Test func mainMigrationRestoreResumesAfterExternalLockAndSavedCopyIsIndependent() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make()
    let moved = URL(fileURLWithPath: f.url.path + "-moved"), linked = URL(fileURLWithPath: f.url.path + "-linked"), recovered = URL(fileURLWithPath: f.url.path + "-copy")
    defer { f.clean(); source.clean(); for url in [moved,linked,recovered] { try? FileManager.default.removeItem(at: url) } }
    _ = try await infrastructureModule(f, source)
    _ = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: linked, mode: .detached))
    let plan = try await f.repo.previewMainRepositoryMigration(to: moved); defer { cleanMigration(plan) }
    let migrated = try await f.repo.migrateMainRepository(plan), record = try #require(try await migrated.mainRepositoryMigrations().first)
    let restoredPlan = try await migrated.previewMainMigrationRestore(record)
    let lock = linked.appendingPathComponent(".git.lock"); try Data("another owner".utf8).write(to: lock)
    await #expect(throws: GitFailure.self) { try await migrated.restoreMainRepositoryMigration(restoredPlan) }
    #expect(FileManager.default.fileExists(atPath: f.url.appendingPathComponent(".git").path))
    #expect(try String(contentsOf: lock, encoding: .utf8) == "another owner")
    try FileManager.default.removeItem(at: lock)
    let original = GitRepository(root: f.url.resolvingSymlinksInPath()), interrupted = try #require(try await original.mainRepositoryMigrations().first)
    #expect(interrupted.state == "restoring")
    _ = try await original.restoreMainRepositoryMigration(try await original.previewMainMigrationRestore(interrupted))
    _ = try await original.checkedWorktree(try #require(try await original.managedWorktrees().first { !$0.isMain }))
    let stored = try #require(try await original.mainRepositoryMigrations().first)
    let recoveredRepo = try await original.recoverSavedMainRepository(try await original.previewSavedMainRepositoryRecovery(stored, to: recovered))
    #expect(try await recoveredRepo.managedWorktrees().count == 1)
    #expect(try await recoveredRepo.managedSubmodules().first?.initialized == true)
    #expect(try await original.managedWorktrees().count == 2)
}

@Test func forceSubmoduleCleanupRetainsConflictStateAndCanRecoverIndependentRepository() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make()
    let recovered = URL(fileURLWithPath: f.url.path + "-saved-module")
    defer { f.clean(); source.clean(); try? FileManager.default.removeItem(at: recovered) }
    let module = try await infrastructureModule(f, source), childRoot = f.url.appendingPathComponent(module.path)
    func git(_ args: [String], allowed: Set<Int32> = [0]) async throws -> GitOutput { try await GitProcess.run(args, at: childRoot, allowed: allowed) }
    for (key,value) in [("user.name","Test"),("user.email","test@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await git(["config",key,value]) }
    _ = try await git(["switch", "-c", "incoming"])
    try Data("incoming\n".utf8).write(to: childRoot.appendingPathComponent("readme.txt")); _ = try await git(["commit", "-am", "Incoming"])
    _ = try await git(["switch", "main"])
    try Data("local\n".utf8).write(to: childRoot.appendingPathComponent("readme.txt")); _ = try await git(["commit", "-am", "Local"])
    _ = try await git(["merge", "incoming"], allowed: [1])
    try Data("never discard me".utf8).write(to: childRoot.appendingPathComponent("untracked"))
    let conflicts = try await git(["ls-files", "--unmerged", "-z"]).data
    let dirty = try #require(try await f.repo.managedSubmodules().first)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(dirty, operation: .forceDeinitialize))
    let backup = try #require(try await f.repo.relatedManagementBackups().first)
    let saved = try await f.repo.recoverSavedModuleRepository(try await f.repo.previewSavedModuleRepositoryRecovery(backup, to: recovered))
    #expect(try await saved.currentOperation() == .merge)
    #expect(try await GitProcess.run(["ls-files", "--unmerged", "-z"], at: recovered).data == conflicts)
    #expect(try String(contentsOf: recovered.appendingPathComponent("untracked"), encoding: .utf8) == "never discard me")
    try await f.repo.restoreRelatedManagement(try await f.repo.previewRelatedManagementRestore(backup))
    #expect(try await git(["ls-files", "--unmerged", "-z"]).data == conflicts)
    #expect(try String(contentsOf: childRoot.appendingPathComponent("untracked"), encoding: .utf8) == "never discard me")
}

@Test func archiveRetainedThenCloneFreshPreservesOldHistoryAndSavedIndex() async throws {
    let f = try await Fixture.make(), old = try await Fixture.make(), fresh = try await Fixture.make()
    let recovered = URL(fileURLWithPath: f.url.path + "-old-repository")
    defer { f.clean(); old.clean(); fresh.clean(); try? FileManager.default.removeItem(at: recovered) }
    try fresh.write("readme.txt", "fresh repository\n"); try await fresh.git(["commit", "-am", "Fresh content"])
    let original = try await infrastructureModule(f, old)
    let childRoot = f.url.appendingPathComponent(original.path)
    try Data("old staged work\n".utf8).write(to: childRoot.appendingPathComponent("readme.txt"))
    _ = try await GitProcess.run(["add", "readme.txt"], at: childRoot)
    let dirty = try #require(try await f.repo.managedSubmodules().first)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(dirty, operation: .forceRemove))
    try await f.git(["commit", "-m", "Remove old module"])
    await #expect(throws: GitFailure.self) { try await f.repo.previewSubmoduleAddition(source: fresh.url.path, path: "new/lib", name: original.name, allowLocalTransport: true, directoryMode: .retainedRepository) }
    let replace = try await f.repo.previewSubmoduleAddition(source: fresh.url.path, path: "new/lib", name: original.name, allowLocalTransport: true, directoryMode: .archiveAndClone)
    try await f.repo.addSubmodule(replace)
    #expect(try String(contentsOf: f.url.appendingPathComponent("new/lib/readme.txt"), encoding: .utf8) == "fresh repository\n")
    let backup = try #require(try await f.repo.relatedManagementBackups().first { $0.title.hasPrefix("Reuse Submodule") })
    let oldCopy = try await f.repo.recoverSavedModuleRepository(try await f.repo.previewSavedModuleRepositoryRecovery(backup, to: recovered))
    #expect(try await oldCopy.headPosition().hash == original.head)
    #expect(try String(contentsOf: recovered.appendingPathComponent("readme.txt"), encoding: .utf8) == "old staged work\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("new/lib/readme.txt"), encoding: .utf8) == "fresh repository\n")
}

@Test func emptyDirectoryReuseChecksNewFilesAndDoesNotOverwriteOccupiedDestinations() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make()
    let empty = URL(fileURLWithPath: f.url.path + "-empty")
    defer { f.clean(); source.clean(); try? FileManager.default.removeItem(at: empty) }
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
    let plan = try await f.repo.previewWorktreeCreation(destination: empty, mode: .new, branch: "reuse", reuseEmptyDirectory: true)
    try Data("new data".utf8).write(to: empty.appendingPathComponent("new"))
    await #expect(throws: GitFailure.self) { try await f.repo.createWorktree(plan) }
    #expect(try String(contentsOf: empty.appendingPathComponent("new"), encoding: .utf8) == "new data")
    try FileManager.default.removeItem(at: empty.appendingPathComponent("new"))
    let tree = try await f.repo.createWorktree(plan)
    #expect(tree.branch == "refs/heads/reuse")
    try FileManager.default.createDirectory(at: f.url.appendingPathComponent("empty/module"), withIntermediateDirectories: true)
    let add = try await f.repo.previewSubmoduleAddition(source: source.url.path, path: "empty/module", name: "empty", allowLocalTransport: true, directoryMode: .emptyDirectory)
    try await f.repo.addSubmodule(add)
    #expect(try await f.repo.managedSubmodules().first?.initialized == true)
}

@Test func pointerRepairResumesAfterMetadataLockAndRejectsForeignGitStorage() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make(), other = try await Fixture.make()
    defer { f.clean(); source.clean(); other.clean() }
    let module = try await infrastructureModule(f, source)
    let moved = f.url.appendingPathComponent("moved/lib")
    try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: f.url.appendingPathComponent(module.path), to: moved)
    let plan = try await f.repo.previewPointerRepair(locations: ["module:main/lib": moved.path], replaceBrokenMarkers: true)
    let lock = URL(fileURLWithPath: module.gitDirectory! + "/config.lock")
    try Data("owner".utf8).write(to: lock)
    await #expect(throws: GitFailure.self) { try await f.repo.applyPointerRepair(plan) }
    #expect(try String(contentsOf: lock, encoding: .utf8) == "owner")
    try FileManager.default.removeItem(at: lock)
    let record = try #require(try await f.repo.pointerRepairBackups().first)
    try await f.repo.resumePointerRepair(record)
    #expect(try await f.repo.managedSubmodules().first?.path == "moved/lib")
    let otherHead = try await other.repo.headPosition()
    try Data(("gitdir: " + other.url.appendingPathComponent(".git").path + "\n").utf8).write(to: moved.appendingPathComponent(".git"))
    await #expect(throws: GitFailure.self) { try await f.repo.previewPointerRepair(replaceBrokenMarkers: true) }
    #expect(try await other.repo.headPosition() == otherHead)
}

@Test func retainedReuseAndArchiveRejectLiveLinkedWorkingTrees() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make()
    let linked = URL(fileURLWithPath: f.url.path + "-child-linked")
    defer { f.clean(); source.clean(); try? FileManager.default.removeItem(at: linked) }
    let module = try await infrastructureModule(f, source), child = f.url.appendingPathComponent(module.path)
    _ = try await GitProcess.run(["worktree", "add", "--detach", linked.path], at: child)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(module, operation: .forceDeinitialize))
    let uninitialized = try #require(try await f.repo.managedSubmodules().first)
    await #expect(throws: GitFailure.self) { try await f.repo.previewSubmodule(uninitialized, operation: .archiveStorage) }
    #expect(try String(contentsOf: linked.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\n")
}

@Test func forcedCleanupCannotFollowAReplacedWorktreeSymbolicLink() async throws {
    let f = try await Fixture.make()
    let first = URL(fileURLWithPath: f.url.path + "-first"), second = URL(fileURLWithPath: f.url.path + "-second"), saved = URL(fileURLWithPath: f.url.path + "-saved")
    defer { f.clean(); for url in [first,second,saved] { try? FileManager.default.removeItem(at: url) } }
    let original = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: first, mode: .detached))
    _ = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: second, mode: .detached))
    try FileManager.default.moveItem(at: first, to: saved)
    try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: second.path)
    await #expect(throws: GitFailure.self) { try await f.repo.removeWorktree(original, force: true) }
    #expect(try String(contentsOf: second.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\n")
    #expect(FileManager.default.fileExists(atPath: saved.appendingPathComponent("readme.txt").path))
}

@Test func archivedUninitializedModuleRecoversSavedIndexFromEmptyWorkingFolder() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make()
    let recovered = URL(fileURLWithPath: f.url.path + "-archived-copy")
    defer { f.clean(); source.clean(); try? FileManager.default.removeItem(at: recovered) }
    let module = try await infrastructureModule(f, source)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(module, operation: .deinitialize))
    let uninitialized = try #require(try await f.repo.managedSubmodules().first)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(uninitialized, operation: .archiveStorage))
    let backup = try #require(try await f.repo.relatedManagementBackups().first)
    let copy = try await f.repo.recoverSavedModuleRepository(try await f.repo.previewSavedModuleRepositoryRecovery(backup, to: recovered))
    #expect(try await copy.headPosition().hash == module.head)
    #expect(try String(contentsOf: recovered.appendingPathComponent("readme.txt"), encoding: .utf8) == String(contentsOf: source.url.appendingPathComponent("readme.txt"), encoding: .utf8))
    #expect(try await copy.snapshot().changes.isEmpty)
}

@Test func forcedBatchCleanupAndPruneRejectReappearingDirectories() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let linked = URL(fileURLWithPath: f.url.path + "-batch")
    defer { try? FileManager.default.removeItem(at: linked) }
    var tree = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: linked, mode: .detached))
    try Data("dirty data".utf8).write(to: linked.appendingPathComponent("untracked"))
    try await f.repo.setWorktreeLocked(tree, locked: true, reason: "offline")
    tree = try #require(try await f.repo.managedWorktrees().first { !$0.isMain })
    let forced = try await f.repo.applyRelatedBatch(try await f.repo.previewWorktreeBatch([tree], operation: .forceUnlockRemove))
    #expect(forced.state == "completed" && forced.items.first?.state == "completed")
    #expect(try await f.repo.relatedManagementBackups().isEmpty == false)
    let missing = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: linked, mode: .detached))
    try FileManager.default.removeItem(at: linked)
    let stale = try #require(try await f.repo.managedWorktrees().first { $0.id == missing.id })
    let prune = try await f.repo.previewWorktreeBatch([stale], operation: .prune)
    try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
    try Data("new owner".utf8).write(to: linked.appendingPathComponent("keep"))
    let stopped = try await f.repo.applyRelatedBatch(prune)
    #expect(stopped.state == "stopped" && stopped.items.first?.state == "failed")
    #expect(try String(contentsOf: linked.appendingPathComponent("keep"), encoding: .utf8) == "new owner")
}

@Test func retainedCleanupProtectsLinkedWorkingTreesOfNestedModules() async throws {
    let f = try await Fixture.make(), middle = try await Fixture.make(), leaf = try await Fixture.make()
    let linked = URL(fileURLWithPath: f.url.path + "-nested-linked")
    defer { f.clean(); middle.clean(); leaf.clean(); try? FileManager.default.removeItem(at: linked) }
    _ = try await infrastructureModule(middle, leaf)
    var outer = try await infrastructureModule(f, middle)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(outer, operation: .initialize, recursive: true, allowLocalTransport: true))
    let child = f.url.appendingPathComponent(outer.path + "/deps/lib")
    _ = try await GitProcess.run(["worktree", "add", "--detach", linked.path], at: child)
    outer = try #require(try await f.repo.managedSubmodules().first)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(outer, operation: .forceDeinitialize))
    let uninitialized = try #require(try await f.repo.managedSubmodules().first)
    await #expect(throws: GitFailure.self) { try await f.repo.previewSubmodule(uninitialized, operation: .archiveStorage) }
    #expect(try await GitRepository.open(linked).headPosition().hash != nil)
}

@Test func mainMigrationRejectsMainAndLinkedIndexLocksAtPreviewAndApply() async throws {
    let f = try await Fixture.make()
    let moved = URL(fileURLWithPath: f.url.path + "-moved"), linked = URL(fileURLWithPath: f.url.path + "-linked")
    defer { f.clean(); try? FileManager.default.removeItem(at: linked) }
    _ = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: linked, mode: .detached))
    let plan = try await f.repo.previewMainRepositoryMigration(to: moved); defer { cleanMigration(plan) }
    let mainLock = f.url.appendingPathComponent(".git/index.lock")
    try Data("owner".utf8).write(to: mainLock)
    await #expect(throws: GitFailure.self) { try await f.repo.previewMainRepositoryMigration(to: moved) }
    await #expect(throws: GitFailure.self) { try await f.repo.migrateMainRepository(plan) }
    #expect(try String(contentsOf: mainLock, encoding: .utf8) == "owner")
    try FileManager.default.removeItem(at: mainLock)
    let gitdir = try await GitProcess.run(["rev-parse", "--absolute-git-dir"], at: linked).text.trimmingCharacters(in: .newlines)
    let linkedLock = URL(fileURLWithPath: gitdir + "/index.lock")
    try Data("linked owner".utf8).write(to: linkedLock)
    await #expect(throws: GitFailure.self) { try await f.repo.migrateMainRepository(plan) }
    #expect(try String(contentsOf: linkedLock, encoding: .utf8) == "linked owner")
    #expect(!FileManager.default.fileExists(atPath: moved.path))
}
