import Foundation
import Synchronization
import Testing
@testable import GitCore

@Test func networkReadReportsCompletionWithoutRecordingArguments() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let events = Mutex<[GitNetworkEvent]>([])
    let context = GitNetworkContext { event in events.withLock { $0.append(event) } }
    _ = try await GitNetworkContexts.$current.withValue(context) {
        try await GitProcess.run(["ls-remote", "--", f.url.path], at: f.url)
    }
    let values = events.withLock { $0 }
    #expect(values.first?.phase == .running && values.last?.phase == .succeeded)
    #expect(values.allSatisfy { $0.command == "ls-remote" && $0.repository == f.url.lastPathComponent })
    #expect(Set(values.map(\.id)).count == 1)
}

@Test func networkProgressCanCancelASlowLocalTransportAndRedactsOutput() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let helper = f.url.appendingPathComponent("fake-ssh.sh")
    try Data("#!/bin/sh\ncase \"$1\" in -G) exit 0;; esac\nprintf 'Receiving objects: 10%%\\npassword=private-fixture-secret\\n' >&2\nsleep 2\nexit 1\n".utf8).write(to: helper)
    let events = Mutex<[GitNetworkEvent]>([])
    let context = GitNetworkContext { event in
        events.withLock { $0.append(event) }
        if event.output.contains("10%") { event.cancellation.cancel() }
    }
    let start = ContinuousClock.now
    await #expect(throws: GitFailure.self) {
        _ = try await GitNetworkContexts.$current.withValue(context) {
            try await GitProcess.run(["-c", "core.sshCommand=/bin/sh " + shellQuote(helper.path), "ls-remote", "ssh://git@fixture.invalid/repo"], at: f.url, timeout: 10)
        }
    }
    let values = events.withLock { $0 }
    #expect(values.contains { $0.phase == .running && $0.output.contains("10%") })
    #expect(values.last?.phase == .cancelled)
    #expect(!values.contains { $0.output.contains("private-fixture-secret") })
    #expect(start.duration(to: .now) < .seconds(2))
}

@Test func credentialHelperOnlyAnswersExactHTTPSHostAndGetRequests() throws {
    let credential = GitStoredCredential(host: "example.invalid", username: "fixture", secret: "fixture-token")
    let input = "protocol=https\nhost=example.invalid\n\n"
    let answer = GitCredentialHelper.response(operation: "get", input: input, credential: credential, expectedHost: "example.invalid")
    #expect(answer == "username=fixture\npassword=fixture-token\n\n")
    for request in ["protocol=http\nhost=example.invalid\n", "protocol=https\nhost=other.invalid\n", "protocol=https\nhost=example.invalid\nusername=other\n"] {
        #expect(GitCredentialHelper.response(operation: "get", input: request, credential: credential, expectedHost: "example.invalid").isEmpty)
    }
    for operation in ["store", "erase"] { #expect(GitCredentialHelper.response(operation: operation, input: input, credential: credential, expectedHost: "example.invalid").isEmpty) }
}

@Test func activityRedactionRemovesURLsKnownSecretsAndTokenPrefixes() {
    let text = "https://user:private@example.invalid/repo?token=private password=another ghp_fixturetoken github_pat_fixture glpat-fixture plain-secret\nAuthorization: Bearer custom-private\nssh://user:private@ssh.invalid/repo"
    let cleaned = GitLogRedaction.clean(text, secrets: ["plain-secret"])
    for value in ["user:", "example.invalid", "another", "fixturetoken", "github_pat_", "glpat-fixture", "plain-secret", "custom-private", "ssh.invalid"] { #expect(!cleaned.contains(value)) }
    #expect(cleaned.contains("[redacted]"))
}

@Test func localLFSAndSubmoduleInspectionDoesNotCreateNetworkActivity() {
    let root = URL(fileURLWithPath: "/tmp/Fixture"), context = GitNetworkContext { _ in }
    for arguments in [["lfs", "version"], ["lfs", "status"], ["lfs", "ls-files", "--json"], ["lfs", "checkout"], ["submodule", "status"], ["submodule", "sync"]] {
        #expect(GitNetworkObservation(arguments: arguments, context: context, root: root) == nil)
    }
    for arguments in [["lfs", "fetch", "origin"], ["submodule", "update", "--init"]] {
        #expect(GitNetworkObservation(arguments: arguments, context: context, root: root)?.command == arguments.prefix(2).joined(separator: " "))
    }
}

@Test func unusedHTTPSAccountDoesNotBlockALocalTransportOrRequireKeychainAccess() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let context = GitNetworkContext(credential: GitCredentialReference(id: UUID(), host: "github.com", executable: "/usr/bin/false")) { _ in }
    _ = try await GitNetworkContexts.$current.withValue(context) {
        try await GitProcess.run(["ls-remote", "--", f.url.path], at: f.url)
    }
}
