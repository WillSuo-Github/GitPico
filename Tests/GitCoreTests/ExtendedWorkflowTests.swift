import Foundation
import Testing
@testable import GitCore

@Test func individualChunksStageAndUnstageWithoutLosingWork() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let original = (1...80).map { "line \($0)" }.joined(separator: "\n") + "\n"
    try f.write("chunks.txt", original)
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Prepare chunks")
    let changed = original.replacingOccurrences(of: "line 3\n", with: "first change\n").replacingOccurrences(of: "line 65\n", with: "second change\n")
    try f.write("chunks.txt", changed)
    let file = try #require(try await f.repo.snapshot().changes.first)
    let diff = try await f.repo.diff(file, staged: false)
    #expect(PatchDocument(diff).hunks.count == 2)
    try await f.repo.stageChunk(file, renderedDiff: diff, hunkID: 0, reverse: false)
    let stagedFile = try #require(try await f.repo.snapshot().changes.first)
    let staged = try await f.repo.diff(stagedFile, staged: true)
    #expect(staged.contains("first change") && !staged.contains("second change"))
    #expect(try String(contentsOf: f.url.appendingPathComponent("chunks.txt"), encoding: .utf8) == changed)
    try await f.repo.stageChunk(stagedFile, renderedDiff: staged, hunkID: 0, reverse: true)
    #expect(!(try await f.repo.snapshot().changes[0].isStaged))
    await #expect(throws: GitFailure.self) { try await f.repo.stageChunk(file, renderedDiff: "stale", hunkID: 0, reverse: false) }
}

@Test func chunkStagingNewFileRoundTrip() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("new file.txt", "first\nsecond\n")
    var file = try #require(try await f.repo.snapshot().changes.first)
    var diff = try await f.repo.diff(file, staged: false)
    try await f.repo.stageChunk(file, renderedDiff: diff, hunkID: 0, reverse: false)
    file = try #require(try await f.repo.snapshot().changes.first)
    diff = try await f.repo.diff(file, staged: true)
    try await f.repo.stageChunk(file, renderedDiff: diff, hunkID: 0, reverse: true)
    #expect(try await f.repo.snapshot().changes[0].isUntracked)
    #expect(try String(contentsOf: f.url.appendingPathComponent("new file.txt"), encoding: .utf8) == "first\nsecond\n")
}

@Test func amendSignOffAndFullMetadata() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let before = try await f.repo.snapshot().commits[0].hash
    try await f.repo.commit(message: "Amended subject\n\nFull message", amend: true, signOff: true)
    let snapshot = try await f.repo.snapshot()
    #expect(snapshot.commits.count == 1 && snapshot.commits[0].hash != before)
    let detail = try await f.repo.detail(snapshot.commits[0])
    #expect(detail.message.contains("Signed-off-by: Test Author <test@example.invalid>"))
    #expect(detail.metadata.committer == "Test Author" && detail.metadata.tree.count == 40)
    #expect(detail.additions == 1 && detail.deletions == 0)
    #expect(snapshot.identity.name == "Test Author")
}

@Test func historyPagingAndSearchBeyondLoadedPage() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    for n in 1...3 {
        try f.write("readme.txt", "version \(n)\n")
        try await f.repo.stage(try await f.repo.snapshot().changes)
        try await f.repo.commit(message: "Change \(n)\n\nBody evidence \(n)")
    }
    var options = HistoryOptions(); options.limit = 1
    var snapshot = try await f.repo.snapshot(options: options)
    #expect(snapshot.commits.count == 1 && snapshot.historyCount == 4)
    options.query = "body EVIDENCE 1"
    snapshot = try await f.repo.snapshot(options: options)
    #expect(snapshot.historyCount == 1 && snapshot.commits[0].subject == "Change 1")
    options.query = ""; options.limit = 20
    #expect(try await f.repo.snapshot(options: options).commits.count == 4)
}

@Test func branchComparisonUsesActualAncestry() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("feature/review")
    try f.write("feature.txt", "feature\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Feature")
    let branch = try #require(try await f.repo.snapshot().references.first { $0.name == "feature/review" })
    let comparison = try await f.repo.compare(branch, to: "refs/heads/main")
    #expect(comparison.ahead == 1 && comparison.behind == 0 && !comparison.isMerged)
    #expect(comparison.commits.count == 1 && comparison.files.map(\.path) == ["feature.txt"])
}

@Test func mergeAndDirtyGuard() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("feature/merge")
    try f.write("feature.txt", "feature\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Feature")
    try await f.repo.switchBranch("main")
    try f.write("dirty.txt", "keep me\n")
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(.merge, revision: "refs/heads/feature/merge") }
    try FileManager.default.removeItem(at: f.url.appendingPathComponent("dirty.txt"))
    try await f.repo.integrate(.merge, revision: "refs/heads/feature/merge")
    #expect(try await f.repo.snapshot().commits[0].subject == "Feature")
    #expect(try await f.repo.currentOperation() == .none)
}

@Test func rebaseAndCherryPick() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("feature/replay")
    try f.write("feature.txt", "feature\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Feature")
    let oldHash = try await f.repo.snapshot().commits[0].hash
    try await f.repo.switchBranch("main")
    try f.write("main.txt", "main\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Main change")
    try await f.repo.createBranch("pick-target")
    try await f.repo.integrate(.cherryPick, revision: oldHash)
    #expect(FileManager.default.fileExists(atPath: f.url.appendingPathComponent("feature.txt").path))
    try await f.repo.switchBranch("feature/replay")
    try await f.repo.integrate(.rebase, revision: "refs/heads/main")
    let snapshot = try await f.repo.snapshot(ref: "refs/heads/feature/replay")
    #expect(snapshot.commits[0].subject == "Feature" && snapshot.commits[0].hash != oldHash)
    #expect(snapshot.commits.count == 3)
}

@Test func mergeConflictCanAbortOrContinue() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("conflicting")
    try f.write("readme.txt", "other\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Other")
    try await f.repo.switchBranch("main")
    try f.write("readme.txt", "main\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Main")
    let before = try await f.git(["rev-parse", "HEAD"]).text
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(.merge, revision: "refs/heads/conflicting") }
    #expect(try await f.repo.snapshot().operation == .merge)
    await #expect(throws: GitFailure.self) { try await f.repo.continueOperation() }
    try await f.repo.abortOperation()
    #expect(try await f.git(["rev-parse", "HEAD"]).text == before)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "main\n")
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(.merge, revision: "refs/heads/conflicting") }
    try f.write("readme.txt", "resolved\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.continueOperation()
    #expect(try await f.repo.currentOperation() == .none)
    #expect(try await f.repo.snapshot().commits[0].parents.count == 2)
}

@Test func numstatRenamesBinaryAndHistoricTree() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let stats = GitParser.statistics(Data("2\t1\tregular.txt\0-\t-\tbinary.bin\01\t0\t\0old.txt\0new.txt\0".utf8))
    #expect(stats["regular.txt"]?.additions == 2 && stats["new.txt"]?.deletions == 0)
    #expect(stats["binary.bin"]?.isBinary == true)
    let commit = try await f.repo.snapshot().commits[0]
    #expect(try await f.repo.fileTree(at: commit.hash) == ["readme.txt"])
    #expect(try await f.repo.historicFile(at: commit.hash, path: "readme.txt") == "original\n")
    try await f.repo.saveIdentity(name: "Local Author", email: "local@example.invalid")
    #expect(try await f.repo.configuration().identity.name == "Local Author")
}

@Test func createAndCloneNeverOverwriteExistingFolders() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let clone = try await GitRepository.create(at: f.url.appendingPathComponent("clone"), source: f.url.path)
    #expect(try await clone.snapshot().commits.count == 1)
    let blankURL = f.url.appendingPathComponent("blank")
    let blank = try await GitRepository.create(at: blankURL)
    #expect(try await blank.snapshot().hasHEAD == false)
    await #expect(throws: GitFailure.self) { _ = try await GitRepository.create(at: blankURL) }
    await #expect(throws: GitFailure.self) { _ = try await GitRepository.create(at: blankURL, source: f.url.path) }
}

@Test func repositorySettingsAndIgnoreFilesRejectStaleWrites() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.saveConfiguration(name: "Local Author", email: "local@example.invalid", description: "Local project", signCommits: false, signingKey: "TEST-KEY")
    var config = try await f.repo.configuration()
    #expect(config.description == "Local project" && config.signingKey == "TEST-KEY" && !config.signCommits)
    try await f.repo.saveConfiguration(name: "Local Author", email: "local@example.invalid", description: "Updated", signCommits: false, signingKey: "")
    config = try await f.repo.configuration()
    #expect(config.signingKey.isEmpty)
    let existing = try await f.repo.readIgnoreFile(.ignores)
    try await f.repo.writeIgnoreFile(.ignores, text: "*.log\n", expected: existing)
    try f.write("output.log", "ignored\n")
    #expect(!(try await f.repo.snapshot().changes.contains { $0.path == "output.log" }))
    await #expect(throws: GitFailure.self) { try await f.repo.writeIgnoreFile(.ignores, text: "stale\n", expected: existing) }
    #expect(try await f.repo.readIgnoreFile(.ignores) == "*.log\n")
    let exclude = try await f.repo.readIgnoreFile(.excludes)
    try await f.repo.writeIgnoreFile(.excludes, text: exclude + "local-only.txt\n", expected: exclude)
    try f.write("local-only.txt", "ignored locally\n")
    #expect(!(try await f.repo.snapshot().changes.contains { $0.path == "local-only.txt" }))
}

@Test(arguments: [GitRepository.Integration.rebase, .cherryPick])
func replayConflictCanAbortAndContinue(_ action: GitRepository.Integration) async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("other")
    try f.write("readme.txt", "other\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Other")
    let other = try await f.git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    try await f.repo.switchBranch("main")
    try f.write("readme.txt", "main\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Main")
    if action == .rebase { try await f.repo.switchBranch("other") }
    let revision = action == .rebase ? "refs/heads/main" : other
    let originalHEAD = try await f.git(["rev-parse", "HEAD"]).text
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(action, revision: revision) }
    #expect(try await f.repo.currentOperation() == (action == .rebase ? .rebase : .cherryPick))
    try await f.repo.abortOperation()
    #expect(try await f.git(["rev-parse", "HEAD"]).text == originalHEAD)
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(action, revision: revision) }
    try f.write("readme.txt", "resolved\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.continueOperation()
    #expect(try await f.repo.currentOperation() == .none)
    #expect(try await f.repo.snapshot().changes.isEmpty)
}
