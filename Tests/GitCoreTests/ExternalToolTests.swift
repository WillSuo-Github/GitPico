import Foundation
import Testing
@testable import GitCore

private func externalConflictFixture() async throws -> Fixture {
    let f = try await Fixture.make()
    try await f.git(["checkout", "-b", "incoming"]); try f.write("readme.txt", "incoming\n"); try await f.git(["add", "."]); try await f.git(["commit", "-m", "Incoming"])
    try await f.git(["checkout", "main"]); try f.write("readme.txt", "current\n"); try await f.git(["add", "."]); try await f.git(["commit", "-m", "Current"])
    try await f.git(["merge", "incoming"], allowed: [1])
    return f
}

@Test func externalDiffSnapshotsPreserveIndexWorkingBytesAndRenameSources() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.git(["mv", "readme.txt", "new name.txt"])
    try f.write("new name.txt", "later\n")
    let staged = try await f.repo.prepareExternalDiff(path: "new name.txt", staged: true)
    let stagedFiles = try await f.repo.externalFiles(staged)
    #expect(try Data(contentsOf: #require(stagedFiles["local"])) == Data("original\n".utf8))
    #expect(try Data(contentsOf: #require(stagedFiles["remote"])) == Data("original\n".utf8))
    let working = try await f.repo.prepareExternalDiff(path: "new name.txt")
    let workingFiles = try await f.repo.externalFiles(working)
    #expect(try Data(contentsOf: #require(workingFiles["remote"])) == Data("later\n".utf8))
    #expect(try await f.git(["show", ":new name.txt"]).text == "original\n")
    #expect(try await f.repo.externalSessions().count == 2)
    try await f.repo.deleteExternalSession(staged.id)
    #expect(try await f.repo.externalSessions().count == 1)
    let parent = try #require(try await f.repo.headPosition().hash)
    // Keep the rename exact so the revision comparison can infer its old name.
    try f.write("new name.txt", "original\n")
    try await f.git(["add", "new name.txt"]); try await f.git(["commit", "-m", "Rename"])
    let compared = try await f.repo.prepareExternalComparison(left: parent, right: "HEAD", path: "new name.txt")
    let comparedFiles = try await f.repo.externalFiles(compared)
    #expect(try Data(contentsOf: #require(comparedFiles["local"])) == Data("original\n".utf8))
}

@Test func externalCommitComparisonSupportsRootAndBinaryCopies() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let hash = try #require(try await f.repo.headPosition().hash)
    let root = try await f.repo.prepareExternalComparison(left: nil, right: hash, path: "readme.txt")
    let files = try await f.repo.externalFiles(root)
    #expect(try Data(contentsOf: #require(files["local"])).isEmpty)
    #expect(try Data(contentsOf: #require(files["remote"])) == Data("original\n".utf8))
    try Data([0, 255, 128]).write(to: f.url.appendingPathComponent("binary"))
    let binary = try await f.repo.prepareExternalDiff(path: "binary"), urls = try await f.repo.externalFiles(binary)
    #expect(try Data(contentsOf: #require(urls["remote"])) == Data([0, 255, 128]))
}

@Test func externalToolArgumentsAreLiteralAndHeadlessRunnerNeverUsesAShell() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let name = "$(touch INJECTED){remote}.txt"
    try f.write(name, "literal\n")
    let session = try await f.repo.prepareExternalDiff(path: name), files = try await f.repo.externalFiles(session)
    let script = f.url.appendingPathComponent("tool stub.sh")
    try "#!/bin/sh\nprintf '%s\\n' \"$1\" \"$2\"\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let command = ExternalToolCommand(executable: script.path, arguments: ["{local}", "{remote}"])
    #expect(try command.invocation(files: files, merge: false) == [files["local"]!.path, files["remote"]!.path])
    let runner = ExternalToolRunner()
    try await runner.launch(command, session: session, files: files)
    let deadline = Date().addingTimeInterval(5)
    while await runner.status(session.id).running && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let result = await runner.status(session.id)
    #expect(!result.running && result.exitCode == 0 && result.diagnostics.contains(name))
    #expect(!FileManager.default.fileExists(atPath: files["merged"]!.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("INJECTED").path))
    #expect(throws: GitFailure.self) { try ExternalToolCommand(executable: script.path, arguments: ["{local}", "{remote}", "{unknown}"]).invocation(files: files, merge: false) }
    await #expect(throws: GitFailure.self) { try await runner.launch(ExternalToolCommand(executable: "/missing/tool", arguments: ["{local}", "{remote}"]), session: session, files: files) }
    try "#!/bin/sh\nprintf 'helper failed\\n' >&2\nexit 7\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try await runner.launch(command, session: session, files: files)
    let failureDeadline = Date().addingTimeInterval(5)
    while await runner.status(session.id).running && Date() < failureDeadline { try await Task.sleep(for: .milliseconds(20)) }
    let failed = await runner.status(session.id)
    #expect(failed.exitCode == 7 && failed.diagnostics.contains("helper failed"))
    #expect(try await f.repo.externalSession(session.id).id == session.id)
}

@Test func externalMergeResultRequiresExplicitApplyAndSurvivesReopen() async throws {
    let f = try await externalConflictFixture(); defer { f.clean() }
    let original = try Data(contentsOf: f.url.appendingPathComponent("readme.txt")), head = try await f.repo.headPosition()
    let session = try await f.repo.prepareExternalMerge(path: "readme.txt"), files = try await f.repo.externalFiles(session)
    try Data("resolved\n".utf8).write(to: #require(files["merged"]), options: .atomic)
    #expect(try Data(contentsOf: f.url.appendingPathComponent("readme.txt")) == original)
    #expect(try await f.repo.snapshot().changes.contains(where: \.isConflicted))
    let reopened = try await GitRepository.open(f.url)
    #expect(try await reopened.externalSessions().first?.id == session.id)
    try await reopened.applyExternalMerge(session.id)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "resolved\n")
    #expect(try await f.git(["show", ":readme.txt"]).text == "resolved\n")
    #expect(try await f.repo.headPosition() == head)
    #expect(try await reopened.externalSession(session.id).applied)
    await #expect(throws: GitFailure.self) { try await reopened.applyExternalMerge(session.id) }
}

@Test func externalMergeRejectsMarkersNewEditsChangedOperationAndLinks() async throws {
    let f = try await externalConflictFixture(); defer { f.clean() }
    let session = try await f.repo.prepareExternalMerge(path: "readme.txt"), files = try await f.repo.externalFiles(session), output = try #require(files["merged"])
    await #expect(throws: GitFailure.self) { try await f.repo.applyExternalMerge(session.id) }
    try Data("resolved\n".utf8).write(to: output)
    try f.write("readme.txt", "external newer edit\n")
    await #expect(throws: GitFailure.self) { try await f.repo.applyExternalMerge(session.id) }
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "external newer edit\n")
    try FileManager.default.removeItem(at: output)
    try FileManager.default.createSymbolicLink(at: output, withDestinationURL: f.url.appendingPathComponent("readme.txt"))
    await #expect(throws: GitFailure.self) { try await f.repo.applyExternalMerge(session.id) }
    try await f.git(["merge", "--abort"])
    await #expect(throws: GitFailure.self) { try await f.repo.applyExternalMerge(session.id) }
}

@Test func externalHeadlessMergeProcessWritesOnlyReviewedResultBeforeApplying() async throws {
    let f = try await externalConflictFixture(); defer { f.clean() }
    let original = try Data(contentsOf: f.url.appendingPathComponent("readme.txt"))
    let session = try await f.repo.prepareExternalMerge(path: "readme.txt"), files = try await f.repo.externalFiles(session)
    let script = f.url.appendingPathComponent("merge stub.sh")
    try "#!/bin/sh\n/bin/sleep 0.2\nprintf 'merged by helper\\n' > \"$4\"\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let command = ExternalToolCommand(executable: script.path, arguments: ["{base}", "{local}", "{remote}", "{merged}"]), runner = ExternalToolRunner()
    try await runner.launch(command, session: session, files: files)
    await #expect(throws: GitFailure.self) { try await runner.launch(command, session: session, files: files) }
    let deadline = Date().addingTimeInterval(5)
    while await runner.status(session.id).running && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await runner.status(session.id).exitCode == 0)
    #expect(try Data(contentsOf: f.url.appendingPathComponent("readme.txt")) == original)
    let reviewed = Data("merged by helper\n".utf8)
    #expect(try Data(contentsOf: #require(files["merged"])) == reviewed)
    try Data("newer helper save\n".utf8).write(to: #require(files["merged"]))
    await #expect(throws: GitFailure.self) { try await f.repo.applyExternalMerge(session.id, expectedResult: reviewed) }
    #expect(try Data(contentsOf: f.url.appendingPathComponent("readme.txt")) == original)
    try await f.repo.applyExternalMerge(session.id, expectedResult: Data("newer helper save\n".utf8))
    #expect(try await f.git(["show", ":readme.txt"]).text == "newer helper save\n")
}
