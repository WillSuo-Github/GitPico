import Foundation
import Testing
@testable import GitCore

@Test func structuredHistoryQueriesFindLiteralPathsAuthorsDatesAndScopedHashes() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("folder/a [x].txt", "one\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Find this message")
    let target = try #require(try await f.repo.headPosition().hash)
    var options = HistoryOptions(); options.query = "author:\"Test Author\" after:2000-01-01 before:2099-12-31 path:\"folder/a [x].txt\" message:\"Find this\""
    #expect(try await f.repo.historyPage(at: f.repo.resolveHistory("main"), options: options).commits.map(\.hash) == [target])
    #expect(try await f.repo.snapshot(options: options).commits.map(\.hash) == [target])
    options.query = "hash:" + String(target.prefix(10)); #expect(try await f.repo.historyPage(at: f.repo.resolveHistory("main"), options: options).commits.map(\.hash) == [target])
    options.query += " message:absent"; #expect(try await f.repo.historyPage(at: f.repo.resolveHistory("main"), options: options).commits.isEmpty)
    try await f.repo.createBranch("private-side"); try f.write("side.txt", "side\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Side only")
    let side = try #require(try await f.repo.headPosition().hash)
    options.query = "hash:" + String(side.prefix(10))
    #expect(try await f.repo.historyPage(at: f.repo.resolveHistory("main"), options: options).commits.isEmpty)
    for query in ["author:\"unclosed", "after:2026-02-30", "path:../outside", "hash:--all"] { #expect(throws: GitFailure.self) { try HistoryQuery(query) } }
}

@Test func rootRebaseAndAutosquashRetainTreeAndUndoOriginalHead() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("feature.txt", "feature\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Feature")
    try f.write("feature.txt", "feature corrected\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "fixup! Feature")
    let oldHead = try await f.repo.headPosition(), tree = try await f.git(["rev-parse", "HEAD^{tree}"]).text
    var plan = try await f.repo.rebasePlan(after: "--root")
    #expect(plan.steps.count == 3 && plan.onto.isEmpty)
    plan.steps[0].action = .reword; plan.steps[0].message = "Reviewed root"
    try plan.applyAutosquash(); try await f.repo.startInteractiveRebase(plan)
    #expect(try await f.git(["rev-list", "--count", "HEAD"]).text.trimmingCharacters(in: .newlines) == "2")
    #expect(try await f.git(["rev-parse", "HEAD^{tree}"]).text == tree)
    #expect(try await f.git(["log", "--format=%s", "--reverse"]).text == "Reviewed root\nFeature\n")
    let undo = try #require(try await f.repo.undoAvailability().undo)
    try await f.repo.undoHistory(expected: undo.id); #expect(try await f.repo.headPosition() == oldHead)
}

@Test func mergePreservingInteractiveRebaseRetainsTwoParentsAndRewordsOrdinaryCommits() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let base = try #require(try await f.repo.headPosition().hash)
    try await f.repo.createBranch("topic"); try f.write("topic.txt", "topic\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Topic")
    try await f.repo.switchBranch("main"); try f.write("main.txt", "main\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Main")
    try await f.git(["merge", "--no-ff", "topic", "-m", "Join topic"])
    let tree = try await f.git(["rev-parse", "HEAD^{tree}"]).text
    var plan = try await f.repo.rebasePlan(after: base)
    #expect(plan.preserveMerges && plan.steps.filter(\.isMerge).count == 1)
    let topic = try #require(plan.steps.firstIndex { $0.originalMessage == "Topic" }); plan.steps[topic].action = .reword; plan.steps[topic].message = "Reviewed topic"
    try await f.repo.startInteractiveRebase(plan)
    #expect(try await f.repo.commit(at: "HEAD").parents.count == 2)
    #expect(try await f.git(["rev-parse", "HEAD^{tree}"]).text == tree)
    #expect(try await f.git(["log", "--format=%s", "HEAD"]).text.contains("Reviewed topic"))
}

@Test func symbolicConflictResolutionStagesTheLinkWithoutFollowingItsTarget() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let link = f.url.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "readme.txt")
    try await f.git(["add", "link"]); try await f.repo.commit(message: "Base link")
    try await f.repo.createBranch("topic"); try FileManager.default.removeItem(at: link); try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/outside/never-read")
    try await f.git(["add", "link"]); try await f.repo.commit(message: "Incoming link")
    try await f.repo.switchBranch("main"); try FileManager.default.removeItem(at: link); try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing-current")
    try await f.git(["add", "link"]); try await f.repo.commit(message: "Current link")
    _ = try await f.git(["merge", "topic"], allowed: [1])
    let conflict = try await f.repo.conflict("link"); #expect(!conflict.canEdit)
    try await f.repo.resolveConflict(conflict, resolution: .version(3))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "/outside/never-read")
    #expect(try await f.git(["show", ":link"]).text == "/outside/never-read")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\n")
    try await f.repo.continueOperation(); #expect(try await f.repo.currentOperation() == .none)
}

@Test func submoduleConflictChoiceChangesOnlyTheIndexPointer() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let old = try #require(try await f.repo.headPosition().hash)
    try f.write("new.txt", "new\n"); try await f.repo.stage(try await f.repo.snapshot().changes); try await f.repo.commit(message: "Next")
    let next = try #require(try await f.repo.headPosition().hash)
    try f.write("module/local.txt", "nested user changes\n")
    let entries = "160000 \(old) 1\tmodule\0" + "160000 \(old) 2\tmodule\0" + "160000 \(next) 3\tmodule\0"
    _ = try await GitProcess.run(["update-index", "-z", "--index-info"], at: f.url, input: Data(entries.utf8))
    let conflict = try await f.repo.conflict("module")
    try await f.repo.resolveConflict(conflict, resolution: .version(3))
    #expect(try await f.git(["ls-files", "--stage", "module"]).text.hasPrefix("160000 " + next + " 0"))
    #expect(try String(contentsOf: f.url.appendingPathComponent("module/local.txt"), encoding: .utf8) == "nested user changes\n")
}

@Test func regularConflictReplacesALeafSymlinkWithoutWritingItsOutsideTarget() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let blob = try await f.git(["rev-parse", "HEAD:readme.txt"]).text.trimmingCharacters(in: .newlines)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-conflict-sentinel-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data("outside sentinel\n".utf8).write(to: outside)
    let file = f.url.appendingPathComponent("readme.txt")
    try FileManager.default.removeItem(at: file); try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: outside.path)
    let entries = (1...3).map { "100644 \(blob) \($0)\treadme.txt\0" }.joined()
    _ = try await GitProcess.run(["update-index", "-z", "--index-info"], at: f.url, input: Data(entries.utf8))
    let snapshot = try await f.repo.conflict("readme.txt")
    #expect(!snapshot.canEdit)
    try await f.repo.resolveConflict(snapshot, resolution: .version(3))
    #expect(try String(contentsOf: file, encoding: .utf8) == "original\n")
    #expect(try String(contentsOf: outside, encoding: .utf8) == "outside sentinel\n")
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular)
}

@Test func symbolicPatchApplyAndRecoveryPreserveTargetsAndOutsideFiles() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let patch = Data("diff --git a/link b/link\nnew file mode 120000\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+/outside/never-read\n\\ No newline at end of file\n".utf8)
    let plan = try await f.repo.previewPatch(patch, destination: .both)
    let backup = try await f.repo.applyLocalChange(plan)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.url.appendingPathComponent("link").path) == "/outside/never-read")
    #expect(try await f.git(["ls-files", "--stage", "link"]).text.hasPrefix("120000 "))
    try await f.repo.restoreLocalChanges(backup.id)
    #expect(try await f.git(["ls-files", "--stage", "link"]).text.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("link").path))
}

@Test func gitlinkPatchIndexOnlyPreservesNestedDirectoryAndCanRecover() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let old = try #require(try await f.repo.headPosition().hash)
    try f.write("module/local.txt", "keep nested data\n")
    let patch = Data("diff --git a/module b/module\nnew file mode 160000\n--- /dev/null\n+++ b/module\n@@ -0,0 +1 @@\n+Subproject commit \(old)\n".utf8)
    let backup = try await f.repo.applyLocalChange(f.repo.previewPatch(patch, destination: .index))
    #expect(try await f.git(["ls-files", "--stage", "module"]).text.hasPrefix("160000 " + old))
    #expect(try String(contentsOf: f.url.appendingPathComponent("module/local.txt"), encoding: .utf8) == "keep nested data\n")
    try await f.repo.restoreLocalChanges(backup.id)
    #expect(try await f.git(["ls-files", "--stage", "module"]).text.isEmpty)
}

@Test func configuredTemplateAndRealSSHCommitAndTagVerification() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("template.txt", "Template subject\n\nBody\n# Instruction only\n")
    try await f.git(["config", "commit.template", "template.txt"])
    #expect(try await f.repo.configuredCommitTemplate() == "Template subject\n\nBody")
    #expect(try await f.repo.signature(of: "HEAD").state == .unsigned)
    let key = try await SSHKeyManager(directory: f.url.appendingPathComponent("keys")).generate(name: "fixture", comment: "fixture@example.invalid")
    try f.write("allowed_signers", "test@example.invalid " + key.publicKey + "\n")
    try await f.git(["config", "gpg.format", "ssh"]); try await f.git(["config", "user.signingkey", key.privateFile.path]); try await f.git(["config", "gpg.ssh.allowedSignersFile", f.url.appendingPathComponent("allowed_signers").path])
    try await f.git(["commit", "--allow-empty", "-S", "-m", "Signed fixture"])
    let signature = try await f.repo.signature(of: "HEAD"); #expect(signature.state == .valid && !signature.fingerprint.isEmpty)
    try await f.git(["tag", "-s", "-m", "Signed tag", "signed-fixture"])
    #expect(try await f.repo.signature(of: "signed-fixture", tag: true).state == .valid)
    try f.write("allowed_signers", "other@example.invalid ssh-ed25519 AAAAinvalid\n")
    #expect(try await f.repo.signature(of: "HEAD").state != .valid)
}
