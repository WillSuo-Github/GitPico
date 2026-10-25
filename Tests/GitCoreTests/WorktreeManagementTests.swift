import Foundation
import Testing
@testable import GitCore

@Test func worktreeCreateModesPreserveMainAndEnforceBranchOccupancy() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let destination = URL(fileURLWithPath: f.url.path + "-linked")
    defer { try? FileManager.default.removeItem(at: destination) }
    try f.write("readme.txt", "local main edit\n")
    let plan = try await f.repo.previewWorktreeCreation(destination: destination, mode: .new, branch: "feature")
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let added = try await f.repo.createWorktree(plan)
    #expect(added.branch == "refs/heads/feature" && !added.isMain)
    #expect(try await f.repo.managedWorktrees().count == 2)
    let child = try await f.repo.checkedWorktree(added)
    #expect(try await child.headPosition().hash == plan.hash)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "local main edit\n")
    await #expect(throws: GitFailure.self) { try await f.repo.previewWorktreeCreation(destination: URL(fileURLWithPath: f.url.path + "-other"), mode: .existing, branch: "feature") }
    await #expect(throws: GitFailure.self) { try await f.repo.previewWorktreeCreation(destination: f.url.appendingPathComponent("inside"), mode: .detached) }
    try await f.repo.removeWorktree(added)
    #expect(try await f.repo.references().contains { $0.fullName == "refs/heads/feature" })
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func worktreeMoveLockAndRepairRetainRegistrationIdentity() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let source = URL(fileURLWithPath: f.url.path + "-source"), moved = URL(fileURLWithPath: f.url.path + "-moved"), repaired = URL(fileURLWithPath: f.url.path + "-repaired")
    defer { for path in [source, moved, repaired] { try? FileManager.default.removeItem(at: path) } }
    let record = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: source, mode: .detached))
    try await f.repo.setWorktreeLocked(record, locked: true, reason: "Offline disk")
    let locked = try #require(try await f.repo.managedWorktrees().first { $0.path == source.path })
    #expect(locked.locked == "Offline disk")
    await #expect(throws: GitFailure.self) { try await f.repo.removeWorktree(locked) }
    try await f.repo.setWorktreeLocked(locked, locked: false)
    let unlocked = try #require(try await f.repo.managedWorktrees().first { $0.path == source.path })
    try await f.repo.moveWorktree(unlocked, to: moved)
    try FileManager.default.moveItem(at: moved, to: repaired)
    let missing = try #require(try await f.repo.managedWorktrees().first { $0.path == moved.path })
    #expect(missing.prunable != nil)
    try await f.repo.repairWorktree(missing, at: repaired)
    let fixed = try #require(try await f.repo.managedWorktrees().first { $0.path == repaired.path })
    #expect(fixed.prunable == nil && fixed.head == record.head)
    _ = try await f.repo.checkedWorktree(fixed)
    try await f.repo.removeWorktree(fixed)
}

@Test func worktreeDirtyIgnoredCurrentAndStaleGuardsPreventRemoval() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let path = URL(fileURLWithPath: f.url.path + "-guard")
    defer { try? FileManager.default.removeItem(at: path) }
    let record = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: path, mode: .new, branch: "guard"))
    let child = try await f.repo.checkedWorktree(record)
    try Data("local\n".utf8).write(to: path.appendingPathComponent("untracked"))
    await #expect(throws: GitFailure.self) { try await f.repo.removeWorktree(record) }
    #expect(FileManager.default.fileExists(atPath: path.appendingPathComponent("untracked").path))
    try FileManager.default.removeItem(at: path.appendingPathComponent("untracked"))
    let current = try #require(try await child.managedWorktrees().first { $0.path == path.path })
    await #expect(throws: GitFailure.self) { try await child.removeWorktree(current) }
    try await f.repo.setWorktreeLocked(record, locked: true)
    await #expect(throws: GitFailure.self) { try await f.repo.removeWorktree(record) }
    let fresh = try #require(try await f.repo.managedWorktrees().first { $0.path == path.path })
    try await f.repo.setWorktreeLocked(fresh, locked: false)
    let unlocked = try #require(try await f.repo.managedWorktrees().first { $0.path == path.path })
    try await f.repo.removeWorktree(unlocked)
}

@Test func worktreeCreationRejectsExistingDestinationsAndChangedBranchPreview() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["branch", "other"])
    let destination = URL(fileURLWithPath: f.url.path + "-stale")
    defer { try? FileManager.default.removeItem(at: destination) }
    let plan = try await f.repo.previewWorktreeCreation(destination: destination, mode: .existing, branch: "other")
    try await f.git(["commit", "--allow-empty", "-m", "Advance"])
    let new = try #require(try await f.repo.headPosition().hash)
    try await f.git(["update-ref", "refs/heads/other", new])
    await #expect(throws: GitFailure.self) { try await f.repo.createWorktree(plan) }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    await #expect(throws: GitFailure.self) { try await f.repo.previewWorktreeCreation(destination: destination, mode: .detached) }
}

@Test func worktreeIgnoredFilesAndWrongRepairFolderAreProtected() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write(".gitignore", "*.cache\n"); try await f.git(["add", "."]); try await f.git(["commit", "-m", "Ignore cache"])
    let destination = URL(fileURLWithPath: f.url.path + "-ignored")
    defer { try? FileManager.default.removeItem(at: destination) }
    let record = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: destination, mode: .detached))
    try Data("precious".utf8).write(to: destination.appendingPathComponent("data.cache"))
    await #expect(throws: GitFailure.self) { try await f.repo.removeWorktree(record) }
    await #expect(throws: GitFailure.self) { try await f.repo.moveWorktree(record, to: URL(fileURLWithPath: f.url.path + "-wrong")) }
    await #expect(throws: GitFailure.self) { try await f.repo.repairWorktree(record, at: f.url) }
    #expect(try Data(contentsOf: destination.appendingPathComponent("data.cache")) == Data("precious".utf8))
    try FileManager.default.removeItem(at: destination.appendingPathComponent("data.cache"))
    try FileManager.default.removeItem(at: destination)
    let missing = try #require(try await f.repo.managedWorktrees().first { !$0.isMain })
    try await f.repo.removeWorktree(missing)
    #expect(try await f.repo.managedWorktrees().count == 1)
}
