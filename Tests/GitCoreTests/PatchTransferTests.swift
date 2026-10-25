import Foundation
import Testing
@testable import GitCore

@Test(arguments: PatchDestination.allCases) func patchRoundTripAndRecovery(destination: PatchDestination) async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "patch content\n")
    let data = try await f.repo.exportPatch(.unstaged)
    try f.write("readme.txt", "original\n")
    let plan = try await f.repo.previewPatch(data, destination: destination)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\n")
    let saved = try await f.repo.applyLocalChange(plan)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == (destination == .index ? "original\n" : "patch content\n"))
    #expect(try await f.git(["show", ":readme.txt"]).text == (destination == .workingCopy ? "original\n" : "patch content\n"))
    try await f.repo.restoreLocalChanges(saved.id)
    #expect(try await f.repo.snapshot().changes.isEmpty)
}

@Test func patchBinaryNewFilesAndDeletedFilesPreserveExactBytes() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let name = ":(glob)* 中文\nfile.bin", bytes = Data([0, 255, 128, 13, 10, 0, 42])
    try bytes.write(to: f.url.appendingPathComponent(name))
    try FileManager.default.removeItem(at: f.url.appendingPathComponent("readme.txt"))
    let data = try await f.repo.exportPatch(.unstaged)
    #expect(String(decoding: data, as: UTF8.self).contains("GIT binary patch"))
    try FileManager.default.removeItem(at: f.url.appendingPathComponent(name)); try f.write("readme.txt", "original\n")
    let plan = try await f.repo.previewPatch(data, destination: .both)
    let saved = try await f.repo.applyLocalChange(plan)
    #expect(try Data(contentsOf: f.url.appendingPathComponent(name)) == bytes)
    #expect(try await f.git(["show", ":" + name]).data == bytes)
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("readme.txt").path))
    try await f.repo.restoreLocalChanges(saved.id)
    #expect(try await f.repo.snapshot().changes.isEmpty)
}

@Test func importedRenamePatchCapturesSourceAndDestination() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let renamed = "中文\nrenamed.txt"
    try await f.git(["mv", "readme.txt", renamed])
    let patch = try await f.git(["diff", "--cached", "--binary", "--find-renames"]).data
    try await f.git(["reset", "--hard", "HEAD"])
    let plan = try await f.repo.previewPatch(patch, destination: .both)
    #expect(Set(plan.paths) == Set(["readme.txt", renamed]))
    let saved = try await f.repo.applyLocalChange(plan)
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("readme.txt").path))
    #expect(try String(contentsOf: f.url.appendingPathComponent(renamed), encoding: .utf8) == "original\n")
    try await f.repo.restoreLocalChanges(saved.id)
    #expect(try await f.repo.snapshot().changes.isEmpty)
}

@Test func patchImportChecksAllFilesBeforeAnyWrite() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("other.txt", "base\n"); try await f.git(["add", "."]); try await f.git(["commit", "-m", "Other"])
    try f.write("readme.txt", "change one\n"); try f.write("other.txt", "change two\n")
    let data = try await f.repo.exportPatch(.unstaged)
    try f.write("readme.txt", "original\n"); try f.write("other.txt", "conflicting external edit\n")
    await #expect(throws: GitFailure.self) { try await f.repo.previewPatch(data, destination: .workingCopy) }
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\n")
    #expect(try await f.repo.localChangeBackups().isEmpty)
    // --index requires matching staged and unstaged baselines.
    await #expect(throws: GitFailure.self) { try await f.repo.previewPatch(data, destination: .both) }
}

@Test func patchTraversalGitMetadataAndSymlinkAreRejected() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    for path in ["../outside", ".git/config", "a/.GIT/config", "/tmp/GitPico-escape"] {
        let patch = Data("diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1 @@\n+malicious\n".utf8)
        await #expect(throws: (any Error).self) { try await f.repo.previewPatch(patch, destination: .workingCopy) }
    }
    let link = Data("diff --git a/link b/link\nnew file mode 120000\nindex 0000000..0000000\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+/tmp/outside\n".utf8)
    await #expect(throws: (any Error).self) { try await f.repo.previewPatch(link, destination: .workingCopy) }
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("link").path))
    #expect(try await f.repo.snapshot().changes.isEmpty)
}

@Test func selectedLinePatchAndReverseImportPreserveOtherChanges() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "first\nsecond\n")
    let change = try #require(try await f.repo.snapshot().changes.first), diff = try await f.repo.diff(change, staged: false)
    let doc = PatchDocument(diff), hunk = try #require(doc.hunks.first)
    let line = try #require(DiffDocument(hunk.text).lines.first { $0.kind == .addition && $0.text.contains("first") })
    let patch = try await f.repo.exportSelectedLines(change, renderedDiff: diff, selection: [PatchLineID(hunk: hunk.id, line: line.id)], staged: false)
    try f.write("readme.txt", "original\n")
    let applied = try await f.repo.previewPatch(patch, destination: .workingCopy)
    try await f.repo.applyLocalChange(applied)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\nfirst\n")
    let reverse = try await f.repo.previewPatch(patch, destination: .workingCopy, reverse: true)
    try await f.repo.applyLocalChange(reverse)
    #expect(try await f.repo.snapshot().changes.isEmpty)
}

@Test func mailboxCommitPatchIncludesRootMetadataAndBinaryChanges() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let rootPatch = try await f.repo.exportPatch(.commit("HEAD"))
    #expect(String(decoding: rootPatch, as: UTF8.self).contains("Subject: [PATCH] Initial | commit"))
    try Data([0, 255, 1, 2]).write(to: f.url.appendingPathComponent("binary"))
    try f.write("readme.txt", "commit patch\n"); try await f.git(["add", "."]); try await f.git(["commit", "-m", "Patch subject"])
    let patch = try await f.repo.exportPatch(.commit("HEAD"))
    #expect(String(decoding: patch, as: UTF8.self).contains("GIT binary patch"))
    try await f.git(["reset", "--hard", "HEAD~1"])
    let head = try await f.repo.headPosition()
    try await f.repo.applyLocalChange(try await f.repo.previewPatch(patch, destination: .both))
    #expect(try await f.repo.headPosition() == head)
    #expect(try Data(contentsOf: f.url.appendingPathComponent("binary")) == Data([0, 255, 1, 2]))
}

@Test func patchStalePreviewAndIgnoredDestinationAreProtected() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("new.txt", "patch\n")
    let patch = try await f.repo.exportPatch(.unstaged, paths: ["new.txt"])
    try FileManager.default.removeItem(at: f.url.appendingPathComponent("new.txt"))
    let plan = try await f.repo.previewPatch(patch, destination: .workingCopy)
    try f.write("new.txt", "external file\n")
    await #expect(throws: GitFailure.self) { try await f.repo.applyLocalChange(plan) }
    try f.write(".gitignore", "new.txt\n")
    await #expect(throws: GitFailure.self) { try await f.repo.previewPatch(patch, destination: .workingCopy) }
    #expect(try String(contentsOf: f.url.appendingPathComponent("new.txt"), encoding: .utf8) == "external file\n")
}

@Test func patchCRLFNoFinalNewlineAndExecutableModeRoundTrip() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "one\r\ntwo"); try await f.git(["add", "."]); try await f.git(["commit", "-m", "CRLF baseline"])
    try f.write("readme.txt", "one\r\nchanged\r\nthree")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.url.appendingPathComponent("readme.txt").path)
    let data = try await f.repo.exportPatch(.unstaged)
    try await f.git(["restore", "--worktree", "readme.txt"])
    let backup = try await f.repo.applyLocalChange(try await f.repo.previewPatch(data, destination: .both))
    #expect(try Data(contentsOf: f.url.appendingPathComponent("readme.txt")) == Data("one\r\nchanged\r\nthree".utf8))
    #expect(try await f.git(["ls-files", "--stage"]).text.hasPrefix("100755"))
    try await f.repo.restoreLocalChanges(backup.id)
    #expect(try Data(contentsOf: f.url.appendingPathComponent("readme.txt")) == Data("one\r\ntwo".utf8))
}

@Test func patchConversionAttributesRequireIndexOnlyWithoutTouchingWorktree() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "patched\n")
    let patch = try await f.repo.exportPatch(.unstaged)
    try f.write("readme.txt", "original\n")
    try f.write(".gitattributes", "*.txt text eol=crlf\n")
    await #expect(throws: GitFailure.self) { try await f.repo.previewPatch(patch, destination: .both) }
    let plan = try await f.repo.previewPatch(patch, destination: .index)
    let saved = try await f.repo.applyLocalChange(plan)
    #expect(try await f.git(["show", ":readme.txt"]).text == "patched\n")
    #expect(try Data(contentsOf: f.url.appendingPathComponent("readme.txt")) == Data("original\n".utf8))
    try await f.repo.restoreLocalChanges(saved.id)
}
