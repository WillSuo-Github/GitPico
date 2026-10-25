import Foundation
import Testing
@testable import GitCore

private func advancedAdd(_ parent: Fixture, _ source: Fixture, path: String, name: String) async throws {
    try await parent.repo.addSubmodule(try await parent.repo.previewSubmoduleAddition(source: source.url.path, path: path, name: name, allowLocalTransport: true))
    try await parent.git(["commit", "-m", "Add " + name])
}
private func advancedNested(_ parent: Fixture, _ middle: Fixture, _ leaf: Fixture) async throws -> ManagedSubmodule {
    try await advancedAdd(middle, leaf, path: "inner/lib [x]", name: "leaf")
    try await advancedAdd(parent, middle, path: "deps/outer", name: "outer")
    let module = try #require(try await parent.repo.managedSubmodules().first)
    try await parent.repo.applySubmodule(try await parent.repo.previewSubmodule(module, operation: .initialize, recursive: true, allowLocalTransport: true))
    return try #require(try await parent.repo.managedSubmodules().first)
}

@Test func nestedSubmoduleMigrationAndManagementRestorePreserveRepositories() async throws {
    let f = try await Fixture.make(), middle = try await Fixture.make(), leaf = try await Fixture.make()
    defer { f.clean(); middle.clean(); leaf.clean() }
    let module = try await advancedNested(f, middle, leaf)
    let index = try await f.repo.submoduleAddIndex(), modules = try Data(contentsOf: f.url.appendingPathComponent(".gitmodules"))
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(module, operation: .move, value: "other/outer 中文"))
    let moved = try #require(try await f.repo.managedSubmodules().first)
    let child = try await f.repo.checkedSubmodule(moved), inner = try #require(try await child.managedSubmodules().first)
    #expect(inner.initialized && inner.head == inner.recordedHash && !inner.dirty)
    let backup = try #require(try await f.repo.relatedManagementBackups().first { $0.title.hasPrefix("Move Submodule") })
    let reopened = try await GitRepository.open(f.url)
    try await reopened.restoreRelatedManagement(try await reopened.previewRelatedManagementRestore(backup))
    let original = try #require(try await reopened.managedSubmodules().first)
    #expect(original.path == module.path && original.head == module.head)
    #expect(try Data(contentsOf: f.url.appendingPathComponent(".gitmodules")) == modules)
    #expect(try await reopened.submoduleAddIndex() == index)
    let restoredChild = try await reopened.checkedSubmodule(original)
    #expect(try await restoredChild.managedSubmodules().first?.head == inner.head)
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("other/outer 中文").path))
}

@Test func nestedWorktreeMoveRemoveAndRestoreRetainModuleGitStorage() async throws {
    let f = try await Fixture.make(), middle = try await Fixture.make(), leaf = try await Fixture.make()
    let linked = URL(fileURLWithPath: f.url.path + "-linked"), moved = URL(fileURLWithPath: f.url.path + "-moved")
    defer { f.clean(); middle.clean(); leaf.clean(); try? FileManager.default.removeItem(at: linked); try? FileManager.default.removeItem(at: moved) }
    _ = try await advancedNested(f, middle, leaf)
    let record = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: linked, mode: .new, branch: "linked"))
    let child = try await f.repo.checkedWorktree(record), module = try #require(try await child.managedSubmodules().first)
    try await child.applySubmodule(try await child.previewSubmodule(module, operation: .initialize, recursive: true, allowLocalTransport: true))
    try await f.repo.moveWorktree(record, to: moved)
    let movedRecord = try #require(try await f.repo.managedWorktrees().first { $0.path == moved.path })
    let movedRepo = try await f.repo.checkedWorktree(movedRecord), movedModule = try #require(try await movedRepo.managedSubmodules().first)
    let moduleRepo = try await movedRepo.checkedSubmodule(movedModule)
    #expect(try await moduleRepo.managedSubmodules().first?.initialized == true)
    let moveBackup = try #require(try await f.repo.relatedManagementBackups().first { $0.title.hasPrefix("Move Worktree") })
    try await f.repo.restoreRelatedManagement(try await f.repo.previewRelatedManagementRestore(moveBackup))
    let restored = try #require(try await f.repo.managedWorktrees().first { $0.path == linked.path })
    try await f.repo.removeWorktree(restored)
    #expect(try await f.repo.managedWorktrees().count == 1)
    let removal = try #require(try await f.repo.relatedManagementBackups().first { $0.title.hasPrefix("Remove Worktree") })
    try await f.repo.restoreRelatedManagement(try await f.repo.previewRelatedManagementRestore(removal))
    let restoredRecord = try #require(try await f.repo.managedWorktrees().first { $0.path == linked.path })
    let restoredRepo = try await f.repo.checkedWorktree(restoredRecord), restoredModule = try #require(try await restoredRepo.managedSubmodules().first)
    #expect(restoredModule.initialized && restoredModule.gitDirectory != nil)
    let restoredModuleRepo = try await restoredRepo.checkedSubmodule(restoredModule)
    #expect(try await restoredModuleRepo.managedSubmodules().first?.initialized == true)
}

@Test func managementRestoreGuardsNewFilesStagingAndChangedBackupAndCanResumeLocks() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make(); defer { f.clean(); source.clean() }
    try await advancedAdd(f, source, path: "deps/lib", name: "lib")
    let module = try #require(try await f.repo.managedSubmodules().first)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(module, operation: .setURL, value: "https://example.invalid/new.git"))
    let backup = try #require(try await f.repo.relatedManagementBackups().first)
    let plan = try await f.repo.previewRelatedManagementRestore(backup)
    try f.write("new", "keep"); try await f.git(["add", "new"])
    await #expect(throws: GitFailure.self) { try await f.repo.restoreRelatedManagement(plan) }
    #expect(try await f.git(["show", ":new"]).text == "keep")
    try await f.git(["restore", "--staged", "new"])
    let fresh = try await f.repo.previewRelatedManagementRestore(backup)
    let lock = f.url.appendingPathComponent(".git/index.lock")
    try Data("owned by another process".utf8).write(to: lock)
    await #expect(throws: GitFailure.self) { try await f.repo.restoreRelatedManagement(fresh) }
    #expect(try Data(contentsOf: lock) == Data("owned by another process".utf8))
    try FileManager.default.removeItem(at: lock)
    let interrupted = try #require(try await f.repo.relatedManagementBackups().first)
    #expect(interrupted.state == "restoring")
    let reopened = try await GitRepository.open(f.url)
    try f.write("deps/lib/new-file", "new while paused")
    await #expect(throws: GitFailure.self) { try await reopened.previewRelatedManagementRestore(interrupted) }
    try FileManager.default.removeItem(at: f.url.appendingPathComponent("deps/lib/new-file"))
    try await reopened.restoreRelatedManagement(try await reopened.previewRelatedManagementRestore(interrupted))
    #expect(try await reopened.managedSubmodules().first?.url == module.url)
    #expect(try String(contentsOf: f.url.appendingPathComponent("new"), encoding: .utf8) == "keep")
    await #expect(throws: GitFailure.self) { try await reopened.previewRelatedManagementRestore(backup) }
}

@Test func managementRestoreRemovalKeepsIgnoredAndNewerFilesAndRejectsTampering() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make(); defer { f.clean(); source.clean() }
    try await advancedAdd(f, source, path: "deps/lib", name: "lib")
    let module = try #require(try await f.repo.managedSubmodules().first)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(module, operation: .remove))
    let backup = try #require(try await f.repo.relatedManagementBackups().first)
    let plan = try await f.repo.previewRelatedManagementRestore(backup)
    try f.write("deps/lib/new-file", "newer")
    await #expect(throws: GitFailure.self) { try await f.repo.restoreRelatedManagement(plan) }
    #expect(try String(contentsOf: f.url.appendingPathComponent("deps/lib/new-file"), encoding: .utf8) == "newer")
    try FileManager.default.removeItem(at: f.url.appendingPathComponent("deps/lib"))
    let record = try await f.repo.loadRelatedBackup(backup.id), directory = try await f.repo.relatedBackupDirectory(backup.id)
    let index = try #require(record.before.directories.firstIndex { $0.digest != nil })
    try Data("tampered".utf8).write(to: directory.appendingPathComponent("directory-\(index)/readme.txt"))
    await #expect(throws: GitFailure.self) { try await f.repo.previewRelatedManagementRestore(backup) }
    await #expect(throws: GitFailure.self) { try await f.repo.restoreRelatedManagement(plan) }
}

@Test func submoduleBatchRemovalSupportsControlledMetadataChangesAndRestoreInReverse() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make(); defer { f.clean(); source.clean() }
    try await advancedAdd(f, source, path: "deps/a", name: "a"); try await advancedAdd(f, source, path: "deps/b", name: "b")
    let modules = try await f.repo.managedSubmodules()
    let batch = try await f.repo.previewSubmoduleBatch(modules, operation: .remove)
    #expect(try await f.repo.managedSubmodules().count == 2)
    let result = try await f.repo.applyRelatedBatch(batch)
    #expect(result.state == "completed" && result.items.allSatisfy { $0.state == "completed" })
    #expect(try await f.repo.managedSubmodules().isEmpty)
    for backup in try await f.repo.relatedManagementBackups().filter({ $0.title.hasPrefix("Remove Submodule") }) {
        try await f.repo.restoreRelatedManagement(try await f.repo.previewRelatedManagementRestore(backup))
    }
    #expect(try await f.repo.managedSubmodules().count == 2)
}

@Test func worktreeBatchStopsAtFailurePersistsAndResumesWithoutReplayingSuccesses() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let a = URL(fileURLWithPath: f.url.path + "-a"), b = URL(fileURLWithPath: f.url.path + "-b")
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let first = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: a, mode: .detached))
    let second = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: b, mode: .detached))
    let plan = try await f.repo.previewWorktreeBatch([first, second], operation: .remove)
    let result = try await f.repo.applyRelatedBatch(plan) { report in
        if report.items.first?.state == "completed" && report.items[1].state == "pending" { try? Data("new edit".utf8).write(to: b.appendingPathComponent("new-file")) }
    }
    #expect(result.state == "stopped" && result.items[0].state == "completed" && result.items[1].state == "failed")
    #expect(!FileManager.default.fileExists(atPath: a.path))
    #expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("new-file").path))
    try FileManager.default.removeItem(at: b.appendingPathComponent("new-file"))
    let reopened = try await GitRepository.open(f.url), stored = try #require(try await reopened.relatedBatchReports().first)
    let resumed = try await reopened.applyRelatedBatch(try await reopened.previewResumeRelatedBatch(stored))
    #expect(resumed.state == "completed" && resumed.items.allSatisfy { $0.state == "completed" })
    #expect(try await reopened.relatedManagementBackups().filter { $0.title.hasPrefix("Remove Worktree") }.count == 2)
}

@Test func worktreeBatchLockMoveAndCancellationRequireFreshPreviews() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let a = URL(fileURLWithPath: f.url.path + "-a"), b = URL(fileURLWithPath: f.url.path + "-b"), destination = URL(fileURLWithPath: f.url.path + "-destination")
    defer { for path in [a,b,destination] { try? FileManager.default.removeItem(at: path) } }
    let first = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: a, mode: .detached))
    let second = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: b, mode: .detached))
    let plan = try await f.repo.previewWorktreeBatch([first, second], operation: .lock, value: "Offline")
    try await f.repo.setWorktreeLocked(second, locked: true)
    await #expect(throws: GitFailure.self) { try await f.repo.applyRelatedBatch(plan) }
    let fresh = try #require(try await f.repo.managedWorktrees().first { $0.path == second.path })
    try await f.repo.setWorktreeLocked(fresh, locked: false)
    let task = Task {
        try await f.repo.applyRelatedBatch(try await f.repo.previewWorktreeBatch([first, second], operation: .lock, value: "Offline")) { progress in
            if progress.items[0].state == "completed" { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    let paused = try await task.value
    #expect(paused.state == "paused" && paused.items[0].state == "completed" && paused.items[1].state == "pending")
    let complete = try await f.repo.applyRelatedBatch(try await f.repo.previewResumeRelatedBatch(paused))
    #expect(complete.state == "completed")
    let locked = try await f.repo.managedWorktrees().filter { !$0.isMain }
    #expect(locked.allSatisfy { $0.locked == "Offline" })
    _ = try await f.repo.applyRelatedBatch(try await f.repo.previewWorktreeBatch(locked, operation: .unlock))
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let unlocked = try await f.repo.managedWorktrees().filter { !$0.isMain }
    let moved = try await f.repo.applyRelatedBatch(try await f.repo.previewWorktreeBatch(unlocked, operation: .move, value: destination.path))
    #expect(moved.state == "completed")
    #expect(try await f.repo.managedWorktrees().filter { !$0.isMain }.allSatisfy { $0.path.hasPrefix(destination.path + "/") })
}

@Test func legacyManagementBackupsRecoverIntoNewTreeWithoutReplacingLiveMetadata() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make()
    let linked = URL(fileURLWithPath: f.url.path + "-legacy"), recovered = URL(fileURLWithPath: f.url.path + "-recovered"), recoveredModule = URL(fileURLWithPath: f.url.path + "-recovered-module")
    defer { f.clean(); source.clean(); for path in [linked,recovered,recoveredModule] { try? FileManager.default.removeItem(at: path) } }
    let worktree = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: linked, mode: .detached))
    let admin = try await f.repo.worktreeAdministration(worktree), legacy = try await f.repo.managementURL("worktree-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: admin, to: legacy)
    try await f.git(["worktree", "remove", "--", linked.path])
    let saved = try #require(try await f.repo.legacyManagementBackups().first)
    let parentHead = try await f.repo.headPosition(), index = try await f.repo.submoduleAddIndex()
    let result = try await f.repo.restoreLegacyManagement(try await f.repo.previewLegacyManagementRestore(saved, to: recovered))
    #expect(result.branch == nil && FileManager.default.fileExists(atPath: recovered.appendingPathComponent("readme.txt").path))
    #expect(try await f.repo.headPosition() == parentHead)
    #expect(try await f.repo.submoduleAddIndex() == index)
    try await advancedAdd(f, source, path: "deps/lib", name: "lib")
    let module = try #require(try await f.repo.managedSubmodules().first), id = UUID()
    let record = SubmoduleManagementBackup(id: id, date: Date(), repository: await f.repo.root.path, module: module, operation: "Change URL", index: try await f.repo.submoduleAddIndex(), gitmodules: try Data(contentsOf: f.url.appendingPathComponent(".gitmodules")), localConfig: try Data(contentsOf: f.url.appendingPathComponent(".git/config")))
    let file = try await f.repo.gitPicoURL("submodule-backups/" + id.uuidString + ".json")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(record).write(to: file)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(module, operation: .setURL, value: "https://example.invalid/new.git"))
    let live = try await f.repo.submoduleAddIndex(), original = try Data(contentsOf: f.url.appendingPathComponent(".gitmodules"))
    let oldModule = try #require(try await f.repo.legacyManagementBackups().first { $0.id.hasPrefix("submodule:") })
    let plan = try await f.repo.previewLegacyManagementRestore(oldModule, to: recoveredModule)
    _ = try await f.repo.restoreLegacyManagement(plan)
    #expect(try await f.repo.submoduleAddIndex() == live)
    #expect(try Data(contentsOf: f.url.appendingPathComponent(".gitmodules")) == original)
    #expect(try String(contentsOf: recoveredModule.appendingPathComponent(".gitmodules"), encoding: .utf8).contains(module.url))
    #expect(!FileManager.default.fileExists(atPath: recoveredModule.appendingPathComponent("deps/lib/.git").path))
    await #expect(throws: GitFailure.self) { try await f.repo.restoreLegacyManagement(plan) }
}

@Test func managementWorktreeRestoreRejectsBranchReuseAndManifestPathTraversal() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let path = URL(fileURLWithPath: f.url.path + "-original"), other = URL(fileURLWithPath: f.url.path + "-other")
    defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: other) }
    let tree = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: path, mode: .new, branch: "saved"))
    try await f.repo.removeWorktree(tree)
    let backup = try #require(try await f.repo.relatedManagementBackups().first)
    let newTree = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: other, mode: .existing, branch: "saved"))
    await #expect(throws: GitFailure.self) { try await f.repo.previewRelatedManagementRestore(backup) }
    try await f.repo.removeWorktree(newTree)
    try await f.git(["commit", "--allow-empty", "-m", "Advance main independently"])
    let mainHead = try await f.repo.headPosition()
    try await f.repo.restoreRelatedManagement(try await f.repo.previewRelatedManagementRestore(backup))
    #expect(try await f.repo.headPosition() == mainHead)
    #expect(try await f.repo.managedWorktrees().contains { $0.path == path.path })
    let record = try await f.repo.loadRelatedBackup(backup.id)
    let invalid = RelatedManagementSnapshot(head: record.before.head, files: record.before.files, directories: [ManagementDirectory(path: record.common + "/../../escape", digest: nil)], pointers: record.before.pointers)
    let corrupt = RelatedManagementRecord(summary: record.summary, repository: record.repository, common: record.common, before: invalid)
    try await f.repo.saveRelatedBackup(corrupt)
    await #expect(throws: GitFailure.self) { try await f.repo.previewRelatedManagementRestore(backup) }
}

@Test func nestedEmbeddedRepositoryMigrationRetainsExternalAndEmbeddedPointers() async throws {
    let f = try await Fixture.make(), middle = try await Fixture.make(), leaf = try await Fixture.make()
    defer { f.clean(); middle.clean(); leaf.clean() }
    var module = try await advancedNested(f, middle, leaf)
    let marker = f.url.appendingPathComponent(module.path + "/.git"), retained = URL(fileURLWithPath: try #require(module.gitDirectory))
    try FileManager.default.removeItem(at: marker)
    try FileManager.default.copyItem(at: retained, to: marker)
    module = try #require(try await f.repo.managedSubmodules().first)
    #expect(module.gitDirectory?.hasSuffix("/deps/outer/.git") == true && !module.dirty)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(module, operation: .move, value: "moved/embedded"))
    let moved = try #require(try await f.repo.managedSubmodules().first)
    let child = try await f.repo.checkedSubmodule(moved)
    #expect(try await child.managedSubmodules().first?.initialized == true)
    let backup = try #require(try await f.repo.relatedManagementBackups().first { $0.title.hasPrefix("Move Submodule") })
    try await f.repo.restoreRelatedManagement(try await f.repo.previewRelatedManagementRestore(backup))
    let restored = try #require(try await f.repo.managedSubmodules().first)
    #expect(restored.path == module.path && restored.gitDirectory == module.gitDirectory && !restored.dirty)
}

@Test func managementBackupRestoreSupportsUnbornParentWithStagedModule() async throws {
    let f = try await Fixture.make(initialCommit: false), source = try await Fixture.make(); defer { f.clean(); source.clean() }
    try await f.repo.addSubmodule(try await f.repo.previewSubmoduleAddition(source: source.url.path, path: "deps/lib", name: "lib", allowLocalTransport: true))
    let module = try #require(try await f.repo.managedSubmodules().first)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(module, operation: .setURL, value: "https://example.invalid/new.git"))
    let backup = try #require(try await f.repo.relatedManagementBackups().first)
    try await f.repo.restoreRelatedManagement(try await f.repo.previewRelatedManagementRestore(backup))
    #expect(try await f.repo.managedSubmodules().first?.url == module.url)
    #expect(try await f.repo.headPosition().hash == nil)
}

@Test func managementLeaseBlocksConcurrentMutationAndReleasesWithoutStaleOwnership() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make(); defer { f.clean(); source.clean() }
    try await advancedAdd(f, source, path: "deps/lib", name: "lib")
    let module = try #require(try await f.repo.managedSubmodules().first)
    let plan = try await f.repo.previewSubmodule(module, operation: .setURL, value: "https://example.invalid/new.git")
    let lease = try await f.repo.acquireRelatedManagementLock()
    let reopened = try await GitRepository.open(f.url)
    await #expect(throws: GitFailure.self) { try await reopened.applySubmodule(plan) }
    #expect(try await f.repo.managedSubmodules().first?.url == module.url)
    await f.repo.releaseRelatedManagementLock(lease)
    try await reopened.applySubmodule(plan)
    #expect(try await reopened.managedSubmodules().first?.url == "https://example.invalid/new.git")
}

@Test func interruptedManagementBackupCanExtractSavedFilesWithoutOverwritingNewEdits() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make()
    let destination = URL(fileURLWithPath: f.url.path + "-extracted")
    defer { f.clean(); source.clean(); try? FileManager.default.removeItem(at: destination) }
    try await advancedAdd(f, source, path: "deps/lib", name: "lib")
    let module = try #require(try await f.repo.managedSubmodules().first)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(module, operation: .setURL, value: "https://example.invalid/new.git"))
    let backup = try #require(try await f.repo.relatedManagementBackups().first)
    var record = try await f.repo.loadRelatedBackup(backup.id)
    record.after = nil; record.summary.state = "prepared"
    try await f.repo.saveRelatedBackup(record)
    try f.write("deps/lib/readme.txt", "new local edit\n")
    await #expect(throws: GitFailure.self) { try await f.repo.previewRelatedManagementRestore(record.summary) }
    let plan = try await f.repo.previewManagementBackupExtraction(record.summary, to: destination)
    try await f.repo.extractManagementBackupFiles(plan)
    #expect(try String(contentsOf: destination.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\n")
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path))
    #expect(try String(contentsOf: f.url.appendingPathComponent("deps/lib/readme.txt"), encoding: .utf8) == "new local edit\n")
    #expect(try await f.repo.managedSubmodules().first?.url == "https://example.invalid/new.git")
    await #expect(throws: GitFailure.self) { try await f.repo.extractManagementBackupFiles(plan) }
}

@Test func managementRestoreRejectsIntentToAddBecomingStagedEmptyFile() async throws {
    let f = try await Fixture.make(), source = try await Fixture.make(); defer { f.clean(); source.clean() }
    try await advancedAdd(f, source, path: "deps/lib", name: "lib")
    try f.write("empty", ""); try await f.git(["add", "-N", "empty"])
    try await f.git(["update-index", "--index-version", "4"])
    let module = try #require(try await f.repo.managedSubmodules().first)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(module, operation: .setURL, value: "https://example.invalid/new.git"))
    let backup = try #require(try await f.repo.relatedManagementBackups().first)
    let preview = try await f.repo.previewRelatedManagementRestore(backup)
    let before = try await f.git(["ls-files", "--stage", "--", "empty"]).data
    try await f.git(["add", "empty"])
    #expect(try await f.git(["ls-files", "--stage", "--", "empty"]).data == before)
    await #expect(throws: GitFailure.self) { try await f.repo.restoreRelatedManagement(preview) }
    await #expect(throws: GitFailure.self) { try await f.repo.previewRelatedManagementRestore(backup) }
    #expect(try await f.git(["diff", "--cached", "--name-only", "--", "empty"]).text == "empty\n")
}

@Test func recursiveManagementRestoreGuardsNewlyInitializedModuleIndexAndHead() async throws {
    let f = try await Fixture.make(), middle = try await Fixture.make(), leaf = try await Fixture.make()
    defer { f.clean(); middle.clean(); leaf.clean() }
    try await advancedAdd(middle, leaf, path: "inner/leaf", name: "leaf")
    try await advancedAdd(f, middle, path: "deps/outer", name: "outer")
    let outer = try #require(try await f.repo.managedSubmodules().first)
    try await f.repo.applySubmodule(try await f.repo.previewSubmodule(outer, operation: .initialize, recursive: true, allowLocalTransport: true))
    let backup = try #require(try await f.repo.relatedManagementBackups().first)
    let preview = try await f.repo.previewRelatedManagementRestore(backup)
    let parent = try await f.repo.checkedSubmodule(try #require(try await f.repo.managedSubmodules().first))
    let inner = try #require(try await parent.managedSubmodules().first), child = try await parent.checkedSubmodule(inner), root = await child.root
    _ = try await GitProcess.run(["update-index", "--assume-unchanged", "readme.txt"], at: root)
    await #expect(throws: GitFailure.self) { try await f.repo.restoreRelatedManagement(preview) }
    _ = try await GitProcess.run(["update-index", "--no-assume-unchanged", "readme.txt"], at: root)
    let tree = try await GitProcess.run(["rev-parse", "HEAD^{tree}"], at: root).text.trimmingCharacters(in: .newlines)
    let identity = ["GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"]
    let next = try await GitProcess.run(["-c", "commit.gpgsign=false", "commit-tree", tree, "-p", inner.head!, "-m", "Empty child commit"], at: root, identityEnvironment: identity).text.trimmingCharacters(in: .newlines)
    _ = try await GitProcess.run(["update-ref", "HEAD", next, inner.head!], at: root)
    await #expect(throws: GitFailure.self) { try await f.repo.previewRelatedManagementRestore(backup) }
    _ = try await GitProcess.run(["update-ref", "HEAD", inner.head!, next], at: root)
    try await f.repo.restoreRelatedManagement(try await f.repo.previewRelatedManagementRestore(backup))
    let restoredParent = try await f.repo.checkedSubmodule(try #require(try await f.repo.managedSubmodules().first))
    #expect(try await restoredParent.managedSubmodules().first?.initialized == false)
}

@Test func independentWorktreeManagementPreservesConflictedParentIndex() async throws {
    let f = try await Fixture.make()
    let linked = URL(fileURLWithPath: f.url.path + "-linked"), moved = URL(fileURLWithPath: f.url.path + "-moved")
    defer { f.clean(); try? FileManager.default.removeItem(at: linked); try? FileManager.default.removeItem(at: moved) }
    let record = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: linked, mode: .detached))
    try await f.git(["switch", "-c", "incoming"]); try f.write("readme.txt", "incoming\n"); try await f.git(["commit", "-am", "Incoming"])
    try await f.git(["switch", "main"]); try f.write("readme.txt", "main\n"); try await f.git(["commit", "-am", "Main"])
    try await f.git(["merge", "incoming"], allowed: [1])
    let conflict = try await f.git(["ls-files", "--unmerged", "-z"]).data
    try await f.repo.moveWorktree(record, to: moved)
    let current = try #require(try await f.repo.managedWorktrees().first { $0.path == moved.path })
    try await f.repo.removeWorktree(current)
    #expect(try await f.git(["ls-files", "--unmerged", "-z"]).data == conflict)
    #expect(try await f.repo.currentOperation() == .merge)
}

@Test func missingWorktreeBackupPinsStagedObjectsAndRecoversSavedIndexAfterGC() async throws {
    let f = try await Fixture.make()
    let linked = URL(fileURLWithPath: f.url.path + "-missing"), recovered = URL(fileURLWithPath: f.url.path + "-recovered")
    defer { f.clean(); try? FileManager.default.removeItem(at: linked); try? FileManager.default.removeItem(at: recovered) }
    let record = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: linked, mode: .detached))
    try Data("staged but never committed\n".utf8).write(to: linked.appendingPathComponent("staged.txt"))
    _ = try await GitProcess.run(["add", "staged.txt"], at: linked)
    let blob = try await GitProcess.run(["rev-parse", ":staged.txt"], at: linked).text.trimmingCharacters(in: .newlines)
    try FileManager.default.removeItem(at: linked)
    let missing = try #require(try await f.repo.managedWorktrees().first { !$0.isMain })
    try await f.repo.removeWorktree(missing)
    try await f.git(["gc", "--prune=now"])
    #expect(try await f.git(["cat-file", "-p", blob]).text == "staged but never committed\n")
    let backup = try #require(try await f.repo.legacyManagementBackups().first { $0.id.hasPrefix("saved-index:") })
    let result = try await f.repo.restoreLegacyManagement(try await f.repo.previewLegacyManagementRestore(backup, to: recovered))
    #expect(result.branch == nil && result.head != record.head)
    #expect(try String(contentsOf: recovered.appendingPathComponent("staged.txt"), encoding: .utf8) == "staged but never committed\n")
}
