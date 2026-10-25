import Foundation
import Testing
@testable import GitCore

private func configureFlow(_ f: Fixture, _ config: GitFlowConfiguration = GitFlowConfiguration()) async throws {
    _ = try await f.repo.applyGitFlow(try await f.repo.previewGitFlowConfiguration(config))
}
private func flowCommit(_ f: Fixture, _ path: String, _ contents: String) async throws {
    try f.write(path, contents); try await f.git(["add", "--", path]); try await f.git(["commit", "-m", path])
}

@Test func gitFlowConfigurationAdoptsClassicKeysAndCreatesDevelopmentWithoutSwitching() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let head = try await f.repo.headPosition()
    var config = GitFlowConfiguration(); config.feature = "topic/"; config.versionTag = "v"
    try await configureFlow(f, config)
    #expect(try await f.repo.gitFlowConfiguration() == config)
    #expect(try await f.repo.headPosition() == head)
    #expect(try await f.repo.verifiedCommit("develop") == head.hash)
    #expect(try await f.git(["config", "--local", "--get", "gitflow.prefix.feature"]).text == "topic/\n")
    config.release = "topic/release/"
    await #expect(throws: GitFailure.self) { try await f.repo.previewGitFlowConfiguration(config) }
    let unborn = try await Fixture.make(initialCommit: false); defer { unborn.clean() }
    await #expect(throws: GitFailure.self) { try await unborn.repo.previewGitFlowConfiguration(GitFlowConfiguration()) }
}

@Test func gitFlowFeatureStartFinishMergesAndPinsBeforeDeletingTopic() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await configureFlow(f)
    let production = try await f.repo.verifiedCommit("main")
    _ = try await f.repo.applyGitFlow(try await f.repo.previewGitFlowStart(.feature, name: "login/ui"))
    #expect(try await f.repo.headPosition().branch == "refs/heads/feature/login/ui")
    try await flowCommit(f, "login.txt", "feature\n")
    let topic = try await f.repo.verifiedCommit("HEAD")
    let record = try #require(try await f.repo.applyGitFlow(try await f.repo.previewGitFlowFinish(branch: "feature/login/ui")))
    #expect(record.state == "completed" && record.next == record.stepCount)
    #expect(try await f.repo.headPosition().branch == "refs/heads/develop")
    #expect(try await f.repo.verifiedCommit("main") == production)
    #expect(try await f.repo.references().contains { $0.fullName == "refs/heads/feature/login/ui" } == false)
    #expect(try await f.git(["merge-base", "--is-ancestor", topic, "develop"]).status == 0)
    #expect(try await f.git(["show", "--format=%P", "--no-patch", "develop"]).text.split(separator: " ").count == 2)
    #expect(try await f.repo.activeGitFlow() == nil)
    #expect(try await f.git(["for-each-ref", "refs/gitpico/checkpoints"]).text.contains(topic))
}

@Test(arguments: [GitFlowKind.release, .hotfix]) func gitFlowReleaseAndHotfixFinishTagProductionAndBackMergeDevelopment(_ kind: GitFlowKind) async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    var config = GitFlowConfiguration(); config.versionTag = "v"
    try await configureFlow(f, config)
    _ = try await f.repo.applyGitFlow(try await f.repo.previewGitFlowStart(kind, name: "1.2.0"))
    try await flowCommit(f, "version.txt", "1.2.0\n")
    let branch = config.prefix(kind) + "1.2.0", topic = try await f.repo.verifiedCommit("HEAD")
    let record = try #require(try await f.repo.applyGitFlow(try await f.repo.previewGitFlowFinish(branch: branch, keepBranch: true, tagMessage: "Release notes")))
    #expect(record.state == "completed")
    let tagged = try await f.repo.verifiedCommit("refs/tags/v1.2.0"), production = try await f.repo.verifiedCommit("main")
    #expect(tagged == production)
    #expect(try await f.git(["cat-file", "-t", "refs/tags/v1.2.0"]).text == "tag\n")
    #expect(try await f.git(["merge-base", "--is-ancestor", "main", "develop"]).status == 0)
    #expect(try await f.repo.verifiedCommit(branch) == topic)
    #expect(try await f.repo.headPosition().branch == "refs/heads/develop")
    #expect(try await f.git(["for-each-ref", "--format=%(contents)", "refs/tags/v1.2.0"]).text.contains("Release notes"))
}

@Test func gitFlowConflictPersistsAcrossReopenAndCanContinueAfterStaging() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await configureFlow(f)
    _ = try await f.repo.applyGitFlow(try await f.repo.previewGitFlowStart(.feature, name: "conflict"))
    try await flowCommit(f, "readme.txt", "feature\n")
    try await f.git(["switch", "develop"]); try await flowCommit(f, "readme.txt", "development\n")
    await #expect(throws: GitFailure.self) { try await f.repo.applyGitFlow(try await f.repo.previewGitFlowFinish(branch: "feature/conflict")) }
    let reopened = try await GitRepository.open(f.url)
    var paused = try #require(try await reopened.activeGitFlow())
    #expect(paused.state == "paused" && paused.next == 1)
    var tampered = paused; tampered.next = -1
    try await reopened.writeManagement(tampered, name: "flow/active.json")
    await #expect(throws: GitFailure.self) { try await reopened.resumeGitFlow(tampered) }
    try await reopened.writeManagement(paused, name: "flow/active.json")
    await #expect(throws: GitFailure.self) { try await reopened.resumeGitFlow(paused) }
    await #expect(throws: GitFailure.self) { try await reopened.previewGitFlowStart(.feature, name: "other") }
    try f.write("readme.txt", "resolved\n"); try await f.git(["add", "readme.txt"])
    paused = try #require(try await reopened.activeGitFlow())
    let completed = try await reopened.resumeGitFlow(paused)
    #expect(completed.state == "completed")
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "resolved\n")
    #expect(try await reopened.currentOperation() == .none)
    #expect(try await reopened.activeGitFlow() == nil)
}

@Test func gitFlowCanAcceptManualMergeCompletionAndProtectsExternalBranchChanges() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await configureFlow(f)
    _ = try await f.repo.applyGitFlow(try await f.repo.previewGitFlowStart(.feature, name: "manual"))
    try await flowCommit(f, "readme.txt", "feature\n")
    try await f.git(["switch", "develop"]); try await flowCommit(f, "readme.txt", "development\n")
    await #expect(throws: GitFailure.self) { try await f.repo.applyGitFlow(try await f.repo.previewGitFlowFinish(branch: "feature/manual")) }
    try f.write("readme.txt", "manual resolution\n"); try await f.git(["add", "readme.txt"]); try await f.git(["commit", "--no-edit"])
    let saved = try #require(try await f.repo.activeGitFlow())
    try await f.git(["branch", "external-change"])
    await #expect(throws: GitFailure.self) { try await f.repo.resumeGitFlow(saved) }
    try await f.git(["branch", "-D", "external-change"])
    let current = try #require(try await f.repo.activeGitFlow())
    #expect(try await f.repo.resumeGitFlow(current).state == "completed")
}

@Test func gitFlowStopAbortsOnlyCurrentMergeAndKeepsEarlierProductionAndTag() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await configureFlow(f)
    try await f.git(["switch", "develop"]); try await flowCommit(f, "readme.txt", "development\n")
    let originalDev = try await f.repo.verifiedCommit("develop")
    _ = try await f.repo.applyGitFlow(try await f.repo.previewGitFlowStart(.hotfix, name: "2.0"))
    try await flowCommit(f, "readme.txt", "hotfix\n")
    await #expect(throws: GitFailure.self) { try await f.repo.applyGitFlow(try await f.repo.previewGitFlowFinish(branch: "hotfix/2.0")) }
    let paused = try #require(try await f.repo.activeGitFlow()), production = try await f.repo.verifiedCommit("main")
    #expect(try await f.repo.verifiedCommit("refs/tags/2.0") == production)
    try await f.repo.stopGitFlow(paused)
    #expect(try await f.repo.currentOperation() == .none)
    #expect(try await f.repo.verifiedCommit("main") == production)
    #expect(try await f.repo.verifiedCommit("develop") == originalDev)
    #expect(try await f.repo.references().contains { $0.name == "hotfix/2.0" })
    #expect(try await f.repo.activeGitFlow() == nil)
    #expect(try await f.repo.gitFlowHistory().first?.state == "stopped")
}

@Test func gitFlowStaleDirtyOccupiedBaseAndVersionCollisionsAreProtected() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let linked = URL(fileURLWithPath: f.url.path + "-flow-linked"); defer { try? FileManager.default.removeItem(at: linked) }
    try await configureFlow(f)
    let stale = try await f.repo.previewGitFlowStart(.feature, name: "stale")
    try await f.git(["branch", "external"])
    await #expect(throws: GitFailure.self) { try await f.repo.applyGitFlow(stale) }
    try f.write("readme.txt", "dirty\n")
    await #expect(throws: GitFailure.self) { try await f.repo.previewGitFlowStart(.feature, name: "dirty") }
    try f.write("readme.txt", "original\n")
    _ = try await f.repo.applyGitFlow(try await f.repo.previewGitFlowStart(.feature, name: "occupied"))
    _ = try await f.repo.createWorktree(try await f.repo.previewWorktreeCreation(destination: linked, mode: .existing, branch: "develop"))
    await #expect(throws: GitFailure.self) { try await f.repo.previewGitFlowFinish(branch: "feature/occupied") }
    _ = try await f.repo.applyGitFlow(try await f.repo.previewGitFlowStart(.release, name: "3.0"))
    await #expect(throws: GitFailure.self) { try await f.repo.previewGitFlowStart(.release, name: "4.0") }
    try await f.repo.createTag("3.0", at: "HEAD")
    await #expect(throws: GitFailure.self) { try await f.repo.previewGitFlowFinish(branch: "release/3.0") }
}

@Test func gitFlowSupportAndRemoteTrackingPreserveClassicBranchBases() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await configureFlow(f)
    _ = try await f.repo.applyGitFlow(try await f.repo.previewGitFlowStart(.support, name: "legacy"))
    let support = try await f.repo.verifiedCommit("HEAD"), production = try await f.repo.verifiedCommit("main")
    #expect(support == production)
    await #expect(throws: GitFailure.self) { try await f.repo.previewGitFlowFinish(branch: "support/legacy") }
    try await f.git(["remote", "add", "origin", f.url.path + "-offline"])
    let hash = try await f.repo.verifiedCommit("HEAD")
    try await f.git(["update-ref", "refs/remotes/origin/feature/shared", hash])
    _ = try await f.repo.applyGitFlow(try await f.repo.previewGitFlowStart(.feature, name: "shared", tracking: "refs/remotes/origin/feature/shared"))
    #expect(try await f.repo.headPosition().branch == "refs/heads/feature/shared")
    #expect(try await f.git(["rev-parse", "--symbolic-full-name", "@{upstream}"]).text == "refs/remotes/origin/feature/shared\n")
}

@Test func gitFlowSigningFailureKeepsTopicAndProductionAndAllowsExplicitStop() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await configureFlow(f)
    let signer = f.url.appendingPathComponent(".git/failing-signer")
    try Data("#!/bin/sh\necho 'Fixture signing failure' >&2\nexit 1\n".utf8).write(to: signer)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: signer.path)
    try await f.git(["config", "gpg.format", "openpgp"]); try await f.git(["config", "gpg.program", signer.path]); try await f.git(["config", "user.signingkey", "fixture-invalid-key"])
    _ = try await f.repo.applyGitFlow(try await f.repo.previewGitFlowStart(.release, name: "signed"))
    try await flowCommit(f, "release.txt", "signed release\n")
    let topic = try await f.repo.verifiedCommit("HEAD")
    await #expect(throws: GitFailure.self) { try await f.repo.applyGitFlow(try await f.repo.previewGitFlowFinish(branch: "release/signed", signTag: true)) }
    let paused = try #require(try await f.repo.activeGitFlow())
    #expect(paused.next == 2)
    #expect(try await f.repo.verifiedCommit("release/signed") == topic)
    #expect(try await f.git(["merge-base", "--is-ancestor", topic, "main"]).status == 0)
    #expect(try await f.repo.references().contains { $0.fullName == "refs/tags/signed" } == false)
    try await f.repo.stopGitFlow(paused)
    #expect(try await f.repo.activeGitFlow() == nil)
    #expect(try await f.repo.verifiedCommit("release/signed") == topic)
}

@Test func gitFlowIgnoredDestinationCannotOverwriteLocalData() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await configureFlow(f)
    try f.write(".gitignore", "collision\n"); try await f.git(["add", ".gitignore"]); try await f.git(["commit", "-m", "Ignore collision"])
    try f.write("collision", "tracked on production\n"); try await f.git(["add", "-f", "collision"]); try await f.git(["commit", "-m", "Production file"])
    try await f.git(["switch", "develop"])
    try await f.git(["config", "core.excludesFile", f.url.appendingPathComponent(".git/fixture-excludes").path])
    try Data("collision\n".utf8).write(to: f.url.appendingPathComponent(".git/fixture-excludes"))
    try f.write("collision", "ignored local file\n")
    let plan = try await f.repo.previewGitFlowStart(.hotfix, name: "protected")
    await #expect(throws: GitFailure.self) { try await f.repo.applyGitFlow(plan) }
    #expect(try String(contentsOf: f.url.appendingPathComponent("collision"), encoding: .utf8) == "ignored local file\n")
    #expect(try await f.repo.references().contains { $0.name == "hotfix/protected" } == false)
}

@Test func gitFlowNeverContinuesOrAbortsAReplacementExternalMerge() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await configureFlow(f)
    _ = try await f.repo.applyGitFlow(try await f.repo.previewGitFlowStart(.feature, name: "owned"))
    try await flowCommit(f, "readme.txt", "flow topic\n")
    try await f.git(["switch", "-c", "external", "main"]); try await flowCommit(f, "readme.txt", "external topic\n")
    try await f.git(["switch", "develop"]); try await flowCommit(f, "readme.txt", "development\n")
    await #expect(throws: GitFailure.self) { try await f.repo.applyGitFlow(try await f.repo.previewGitFlowFinish(branch: "feature/owned")) }
    try await f.git(["merge", "--abort"])
    try await f.git(["merge", "external"], allowed: [1])
    try f.write("readme.txt", "external staged resolution\n"); try await f.git(["add", "readme.txt"])
    let head = try await f.repo.headPosition(), index = try await f.repo.submoduleAddIndex()
    var active = try #require(try await f.repo.activeGitFlow())
    await #expect(throws: GitFailure.self) { try await f.repo.resumeGitFlow(active) }
    active = try #require(try await f.repo.activeGitFlow())
    await #expect(throws: GitFailure.self) { try await f.repo.stopGitFlow(active) }
    #expect(try await f.repo.headPosition() == head)
    #expect(try await f.repo.submoduleAddIndex() == index)
    #expect(try await f.repo.currentOperation() == .merge)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "external staged resolution\n")
}
