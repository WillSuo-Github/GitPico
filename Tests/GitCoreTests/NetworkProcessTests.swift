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

@Test func gitSelectsSavedHTTPSAccountsByHostAndUsername() async throws {
    let fixture = try await Fixture.make(); defer { fixture.clean() }
    let helper = fixture.url.appendingPathComponent("fixture credential helper")
    try Data("""
    #!/bin/sh
    test "$1" = --gitpico-credential-helper && test "$2" = get || exit 0
    printf 'username=fixture\\npassword=%s\\n' "$GITPICO_CREDENTIAL_ID"
    """.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let systemHelper = #"!f() { test "$1" = get && printf 'username=system\npassword=system\n'; }; f"#
    _ = try await GitProcess.run(["config", "--local", "--add", "credential.helper", ""], at: fixture.url)
    _ = try await GitProcess.run(["config", "--local", "--add", "credential.helper", systemHelper], at: fixture.url)
    let host = "fixture.invalid"
    let fallback = GitCredentialReference(id: UUID(), host: host, executable: helper.path)
    let first = GitCredentialReference(id: UUID(), host: host, executable: helper.path, username: "alice")
    let second = GitCredentialReference(id: UUID(), host: host, executable: helper.path, username: "ops+ci")
    let otherHost = GitCredentialReference(id: UUID(), host: "other.invalid", executable: helper.path, username: "alice")
    let accounts = [first, second, otherHost]
    let clone = GitNetworkContext(credential: fallback, matchingCredentials: accounts) { _ in }
    let automatic = GitNetworkContext(matchingCredentials: accounts) { _ in }
    let single = GitNetworkContext(matchingCredentials: [first]) { _ in }
    let background = GitNetworkContext(matchingCredentials: accounts, nonInteractive: true) { _ in }
    func fill(_ url: String, in context: GitNetworkContext) async throws -> GitOutput {
        try await GitNetworkContexts.$current.withValue(context) {
            try await GitProcess.run(["credential", "fill"], at: fixture.url, allowed: [0, 128], input: Data("url=\(url)\n\n".utf8))
        }
    }
    let cases: [(String, GitNetworkContext, String)] = [
        ("https://alice@fixture.invalid/repo", clone, first.id.uuidString),
        ("https://ops%2Bci@fixture.invalid/repo", automatic, second.id.uuidString),
        ("https://alice@other.invalid/repo", automatic, otherHost.id.uuidString),
        ("https://alice@fixture.invalid/repo", background, first.id.uuidString),
        ("https://fixture.invalid/repo", clone, fallback.id.uuidString),
        ("https://fixture.invalid/repo", automatic, "system"),
        ("https://unknown@fixture.invalid/repo", automatic, "system"),
        ("https://unknown@fixture.invalid/repo", single, "system"),
        ("https://fixture.invalid/repo", single, "system"),
        ("https://other.invalid/repo", background, otherHost.id.uuidString),
        ("https://alice@fixture.invalid:8443/repo", automatic, "system"),
        ("http://alice@fixture.invalid/repo", automatic, "system")
    ]
    for (url, context, expected) in cases {
        let result = try await fill(url, in: context)
        #expect(result.status == 0 && result.text.contains("password=\(expected)\n"), "Unexpected credential source for \(url)")
    }
    let noBackgroundFallback = try await fill("https://fixture.invalid/repo", in: background)
    #expect(noBackgroundFallback.status == 128 && noBackgroundFallback.text.isEmpty)
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

@Test func verboseTransportFailureRetainsFinalDiagnosticsPastStderrLimit() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let helper = f.url.appendingPathComponent("verbose-ssh.sh")
    try Data("""
    #!/bin/sh
    case "$1" in -G) exit 0;; esac
    printf 'obsolete-first-page-marker\\n' >&2
    i=0
    while [ "$i" -lt 4000 ]; do
        printf 'Counting objects: 64%% (58/90)\\r' >&2
        i=$((i + 1))
    done
    printf '\\nfatal: fixture transport disconnected at end of output\\n' >&2
    exit 1
    """.utf8).write(to: helper)
    let events = Mutex<[GitNetworkEvent]>([])
    let context = GitNetworkContext { event in events.withLock { $0.append(event) } }
    do {
        _ = try await GitNetworkContexts.$current.withValue(context) {
            try await GitProcess.run(["-c", "core.sshCommand=/bin/sh " + shellQuote(helper.path), "ls-remote", "ssh://git@fixture.invalid/repo"], at: f.url)
        }
        Issue.record("The fixture transport must fail.")
    } catch let failure as GitFailure {
        #expect(failure.message.contains("fixture transport disconnected at end of output"))
        #expect(!failure.message.contains("obsolete-first-page-marker"))
        #expect(failure.message.utf8.count < 66_000)
    }
    let final = try #require(events.withLock { $0.last })
    #expect(final.phase == .failed && final.output.contains("fixture transport disconnected at end of output"))
}
