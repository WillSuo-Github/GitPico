import Foundation
import Testing
@testable import GitCore

@Test func aiCommitContextIncludesOnlyStagedContentAndDoesNotRunDiffDrivers() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "staged change\n"); try await f.git(["add", "readme.txt"])
    try f.write("readme.txt", "private unstaged text\n"); try f.write("private.txt", "private untracked text\n")
    try f.write(".gitattributes", "*.txt diff=evil\n")
    try await f.git(["config", "diff.evil.command", "touch DIFF_DRIVER_RAN"])
    try await f.git(["config", "diff.evil.textconv", "touch TEXTCONV_RAN"])
    let index = try Data(contentsOf: f.url.appendingPathComponent(".git/index")), head = try await f.repo.headPosition()
    let context = try await f.repo.aiCommitContext()
    #expect(context.diff.contains("+staged change"))
    #expect(!context.diff.contains("private unstaged") && !context.diff.contains("private.txt"))
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("DIFF_DRIVER_RAN").path))
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("TEXTCONV_RAN").path))
    #expect(try Data(contentsOf: f.url.appendingPathComponent(".git/index")) == index)
    #expect(try await f.repo.headPosition() == head)
    try f.write("readme.txt", "different unstaged text\n")
    #expect(try await f.repo.aiCommitFingerprint() == context.fingerprint)
    try await f.git(["add", "readme.txt"])
    #expect(try await f.repo.aiCommitFingerprint() != context.fingerprint)
}

@Test func aiCommitContextSupportsInitialBinaryAndRenamedFilesAndRejectsEmptyOrLargeDiffs() async throws {
    let f = try await Fixture.make(initialCommit: false); defer { f.clean() }
    await #expect(throws: GitFailure.self) { try await f.repo.aiCommitContext() }
    try Data([0, 1, 255]).write(to: f.url.appendingPathComponent("asset.bin"))
    try await f.git(["add", "asset.bin"])
    #expect(try await f.repo.aiCommitContext().diff.contains("Binary files"))
    try await f.git(["commit", "-m", "Initial binary"])
    try await f.git(["mv", "asset.bin", "renamed.bin"])
    let renamed = try await f.repo.aiCommitContext()
    #expect(renamed.diff.contains("asset.bin") && renamed.diff.contains("renamed.bin"))
    try f.write("large.txt", String(repeating: "long line\n", count: 15_000))
    try await f.git(["add", "large.txt"])
    do {
        _ = try await f.repo.aiCommitContext()
        Issue.record("Expected the AI-specific staged diff size failure")
    } catch let error as GitFailure {
        #expect(error.message.contains("96 KB maximum"))
    }
}

@Test func aiCommitParserRejectsDiagnosticsAndMalformedMessages() throws {
    #expect(try AICommitMessage.parse("```json\n{\"summary\":\"Update docs\",\"body\":\"Explain setup.\"}\n```") == AICommitMessage(summary: "Update docs", body: "Explain setup."))
    for text in ["", "Please log in", "{\"summary\":\"\",\"body\":\"\"}", "{\"summary\":\"One\\nTwo\",\"body\":\"\"}", "{\"summary\":\"OK\",\"body\":\"bad\\u001b[31m\"}"] {
        #expect(throws: GitFailure.self) { try AICommitMessage.parse(text) }
    }
}

@Test func aiCommitAllChangesIncludesUnstagedAndUntrackedWithoutChangingIndex() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "staged content\n"); try await f.git(["add", "readme.txt"])
    try f.write("readme.txt", "unstaged content\n")
    try f.write("new file [literal].txt", "new untracked content\n")
    try f.write(".gitignore", "private.txt\n"); try f.write("private.txt", "ignored secret\n")
    try f.write(".gitattributes", "*.txt diff=evil\n")
    try await f.git(["config", "diff.evil.command", "touch DIFF_DRIVER_RAN"])
    try await f.git(["config", "diff.evil.textconv", "touch TEXTCONV_RAN"])
    let index = try Data(contentsOf: f.url.appendingPathComponent(".git/index"))
    let head = try await f.repo.headPosition()
    let context = try await f.repo.aiCommitContext(scope: .allChanges)
    #expect(context.diff.contains("+staged content") && context.diff.contains("+unstaged content"))
    #expect(context.diff.contains("new file [literal].txt") && context.diff.contains("+new untracked content"))
    #expect(!context.diff.contains("ignored secret"))
    #expect(context.prompt(language: "English").contains("staged and unstaged diffs"))
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("DIFF_DRIVER_RAN").path))
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("TEXTCONV_RAN").path))
    #expect(try Data(contentsOf: f.url.appendingPathComponent(".git/index")) == index)
    #expect(try await f.repo.headPosition() == head)
    try f.write("new file [literal].txt", "changed untracked content\n")
    #expect(try await f.repo.aiCommitFingerprint(scope: .allChanges) != context.fingerprint)
}

@Test func aiCommitAllChangesSupportsUnbornDeletedAndBinaryFilesAndTracksBinaryEdits() async throws {
    let f = try await Fixture.make(initialCommit: false); defer { f.clean() }
    await #expect(throws: GitFailure.self) { try await f.repo.aiCommitContext(scope: .allChanges) }
    try f.write("new.txt", "untracked on unborn branch\n")
    #expect(try await f.repo.aiCommitContext(scope: .allChanges).diff.contains("+untracked on unborn branch"))
    try Data([0, 1, 2]).write(to: f.url.appendingPathComponent("binary.dat"))
    try await f.git(["add", "."]); try await f.git(["commit", "-m", "Initial files"])
    try FileManager.default.removeItem(at: f.url.appendingPathComponent("new.txt"))
    try Data([0, 2, 3]).write(to: f.url.appendingPathComponent("binary.dat"))
    let context = try await f.repo.aiCommitContext(scope: .allChanges)
    #expect(context.diff.contains("deleted file") && context.diff.contains("Binary files"))
    try Data([0, 4, 5]).write(to: f.url.appendingPathComponent("binary.dat"))
    #expect(try await f.repo.aiCommitFingerprint(scope: .allChanges) != context.fingerprint)
}

@Test func aiCommitAllChangesEnforcesCombinedDiffLimit() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("staged.txt", String(repeating: "staged line\n", count: 4_500))
    try await f.git(["add", "staged.txt"])
    try f.write("untracked.txt", String(repeating: "untracked line\n", count: 3_500))
    #expect(try await f.repo.aiCommitContext().diff.utf8.count < 96 * 1024)
    do {
        _ = try await f.repo.aiCommitContext(scope: .allChanges)
        Issue.record("Expected the combined AI diff size failure")
    } catch let error as GitFailure {
        #expect(error.message.contains("96 KB maximum"))
    }
}

private func aiStub(_ f: Fixture, _ body: String) throws -> URL {
    let executable = f.url.appendingPathComponent("AI CLI $(literal) stub.sh")
    try ("#!/bin/sh\n" + body).write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
}

@Test(arguments: AICommitProvider.allCases) func aiCommitRunnerUsesLiteralPathsAndIsolatedDirectory(provider: AICommitProvider) async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let executable = try aiStub(f, """
    case "$PWD" in *GitPico-AI-*) ;; *) exit 8;; esac
    case "$1" in
      --print|--prompt) if [ "$2" != '--output-format' ]; then request="$2"; else request=$(/bin/cat); fi;;
      *) request=$(/bin/cat);;
    esac
    case "$request" in *'$(touch INJECTED)'*) ;; *) exit 9;; esac
    printf '%s' '{"summary":"Keep literal input","body":"Only staged data."}'
    """)
    let result = try await AICommitCLI().generate(provider: provider, executable: executable, prompt: "Data: $(touch INJECTED)")
    #expect(result.summary == "Keep literal input")
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("INJECTED").path))
}

@Test func aiCommitRunnerReportsErrorsWithoutLeakingDiagnosticsAndStopsOnTimeoutOrCancel() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let executable = try aiStub(f, "printf '%s' 'SECRET_PROMPT_OR_TOKEN' >&2\nexit 3\n")
    do { _ = try await AICommitCLI().generate(provider: .codex, executable: executable, prompt: "Synthetic context"); Issue.record("Expected CLI failure") }
    catch { #expect(!error.localizedDescription.contains("SECRET_PROMPT_OR_TOKEN") && error.localizedDescription.contains("status 3")) }
    _ = try aiStub(f, "exec /bin/sleep 10\n")
    let started = Date()
    await #expect(throws: GitFailure.self) { try await AICommitCLI(timeout: 0.1).generate(provider: .codex, executable: executable, prompt: "Synthetic context") }
    #expect(Date().timeIntervalSince(started) < 3)
    let task = Task { try await AICommitCLI().generate(provider: .codex, executable: executable, prompt: "Synthetic context") }
    try await Task.sleep(for: .milliseconds(100)); task.cancel()
    do { _ = try await task.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_VERIFY_AI_COMMIT_LIVE"] == "1", "Explicit paid CLI integration with synthetic diff only."), arguments: AICommitProvider.allCases)
func aiCommitLiveCLIWithSyntheticStagedDiff(provider: AICommitProvider) async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "original\nDocument the setup steps.\n"); try await f.git(["add", "readme.txt"])
    let context = try await f.repo.aiCommitContext()
    let executable = try #require(provider.executable())
    let result = try await AICommitCLI().generate(provider: provider, executable: executable, prompt: context.prompt(language: "English"))
    #expect(!result.summary.isEmpty)
    #expect(try await f.repo.aiCommitFingerprint() == context.fingerprint)
}
