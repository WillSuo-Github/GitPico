import Foundation
import Testing
@testable import GitCore

@Test func workingFileBrowserIncludesCleanDeletedIgnoredLiteralAndIndexFlags() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write(".gitignore", "build/\n*.log\n!keep.log\n")
    for path in ["build/ignored.txt", "debug.log", "keep.log", ":(glob)* 中文\nfile.txt", "assume", "skip"] { try f.write(path, path + "\n") }
    try await f.git(["add", "assume", "skip"]); try await f.git(["commit", "-m", "Flags"])
    try await f.git(["update-index", "--assume-unchanged", "assume"])
    try await f.git(["update-index", "--skip-worktree", "skip"])
    let without = try await f.repo.workingFiles()
    #expect(without.contains { $0.path == "readme.txt" && $0.change == nil && $0.isTracked })
    #expect(!without.contains { $0.isIgnored })
    #expect(without.contains { $0.path == "assume" && $0.assumeUnchanged })
    #expect(without.contains { $0.path == "skip" && $0.skipWorktree })
    let all = try await f.repo.workingFiles(includeIgnored: true)
    #expect(Set(all.filter(\.isIgnored).map(\.path)) == ["build/ignored.txt", "debug.log"])
    #expect(all.contains { $0.path == "keep.log" && $0.change?.isUntracked == true })
    #expect(all.contains { $0.path == ":(glob)* 中文\nfile.txt" })
    try FileManager.default.removeItem(at: f.url.appendingPathComponent("readme.txt"))
    #expect(try await f.repo.workingFiles().contains { $0.path == "readme.txt" && $0.change?.worktree == "D" })
    await #expect(throws: GitFailure.self) { try await f.repo.workingFiles(limit: 1) }
}

@Test func ignoredForceAddUsesReviewedIndexBackupAndRejectsNewContent() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write(".gitignore", "*.log\n"); try f.write("secret.log", "first\n")
    let stale = try await f.repo.previewForceAddIgnored(["secret.log"])
    #expect(try await f.git(["ls-files", "--", "secret.log"]).data.isEmpty)
    try f.write("secret.log", "second\n")
    await #expect(throws: GitFailure.self) { try await f.repo.applyLocalChange(stale) }
    let plan = try await f.repo.previewForceAddIgnored(["secret.log"])
    let saved = try await f.repo.applyLocalChange(plan)
    #expect(try await f.git(["show", ":secret.log"]).text == "second\n")
    try await f.repo.restoreLocalChanges(saved.id)
    #expect(try await f.git(["ls-files", "--", "secret.log"]).data.isEmpty)
    #expect(try String(contentsOf: f.url.appendingPathComponent("secret.log"), encoding: .utf8) == "second\n")
    await #expect(throws: GitFailure.self) { try await f.repo.previewForceAddIgnored(["readme.txt"]) }
}

@Test func workingFilePreviewDoesNotFollowLinksOrReadDirectories() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try Data([0, 255, 128]).write(to: f.url.appendingPathComponent("binary"))
    #expect(try await f.repo.workingFileData("binary") == Data([0, 255, 128]))
    try FileManager.default.createSymbolicLink(atPath: f.url.appendingPathComponent("link").path, withDestinationPath: "readme.txt")
    for path in ["link", "../outside", ".git/config", "absent"] {
        await #expect(throws: (any Error).self) { try await f.repo.workingFileData(path) }
    }
}
