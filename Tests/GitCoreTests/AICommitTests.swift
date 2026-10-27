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
    await #expect(throws: GitFailure.self) { try await f.repo.aiCommitContext() }
}

@Test func aiCommitParserRejectsDiagnosticsAndMalformedMessages() throws {
    #expect(try AICommitMessage.parse("```json\n{\"summary\":\"Update docs\",\"body\":\"Explain setup.\"}\n```") == AICommitMessage(summary: "Update docs", body: "Explain setup."))
    for text in ["", "Please log in", "{\"summary\":\"\",\"body\":\"\"}", "{\"summary\":\"One\\nTwo\",\"body\":\"\"}", "{\"summary\":\"OK\",\"body\":\"bad\\u001b[31m\"}"] {
        #expect(throws: GitFailure.self) { try AICommitMessage.parse(text) }
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
