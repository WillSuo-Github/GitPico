import Foundation
import GitCore
import Synchronization
import Testing
@testable import GitPico

private final class MemoryCredentialVault: CredentialStoring, Sendable {
    private let values = Mutex<[UUID: GitStoredCredential]>([:])
    func save(_ value: GitStoredCredential, id: UUID) throws { values.withLock { $0[id] = value } }
    func read(_ id: UUID) throws -> GitStoredCredential {
        guard let value = values.withLock({ $0[id] }) else { throw GitFailure("Missing test credential") }
        return value
    }
    func remove(_ id: UUID) throws { values.withLock { $0.removeValue(forKey: id) } }
}

@Test @MainActor func authenticationProfilesKeepTokensOutOfSettingsAndSupportRepoAssignment() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-auth-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let vault = MemoryCredentialVault(), root = directory.appendingPathComponent("Repo")
    let file = directory.appendingPathComponent("authentication.json")
    let store = AuthenticationStore(file: file, vault: vault)
    let profile = try store.add(provider: .github, host: "GitHub.com", username: "fixture", token: "fixture-secret", for: root)
    #expect(store.profile(for: root) == profile)
    #expect(try vault.read(profile.id).secret == "fixture-secret")
    #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("fixture-secret"))
    let reopened = AuthenticationStore(file: file, vault: vault)
    #expect(reopened.profile(for: root)?.host == "github.com")
    try reopened.replaceToken(profile, token: "rotated-secret")
    #expect(reopened.profile(for: root)?.id == profile.id)
    #expect(try vault.read(profile.id).secret == "rotated-secret")
    #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("rotated-secret"))
    try reopened.assign(nil, to: root)
    #expect(reopened.profile(for: root) == nil)
    try reopened.remove(profile)
    #expect(throws: GitFailure.self) { _ = try vault.read(profile.id) }
    #expect(reopened.profiles.isEmpty)
}

@Test @MainActor func authenticationRejectsInvalidHostsAndStaleMetadata() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-auth-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for host in ["https://example.invalid", "user@example.invalid", "example.invalid/path", "example.invalid?token=secret", "example.invalid\n"] {
        #expect(throws: GitFailure.self) { _ = try AuthenticationStore.host(host) }
    }
    let file = directory.appendingPathComponent("auth.json"), vault = MemoryCredentialVault()
    let first = AuthenticationStore(file: file, vault: vault), second = AuthenticationStore(file: file, vault: vault)
    _ = try first.add(provider: .gitlab, host: "example.invalid:8443", username: "first", token: "first-secret", for: nil)
    #expect(throws: GitFailure.self) { _ = try second.add(provider: .github, host: "other.invalid", username: "second", token: "second-secret", for: nil) }
    #expect(second.profiles.isEmpty)
    #expect(AuthenticationStore(file: file, vault: vault).profiles.count == 1)
}

@Test func hostingAccountRequestsBindCredentialsToHTTPSAndProvider() throws {
    let github = AuthenticationProfile(id: UUID(), provider: .github, host: "github.com", username: "fixture")
    let request = try HostingAccountClient.request(github, credential: GitStoredCredential(host: "github.com", username: "fixture", secret: "fixture-secret"))
    #expect(request.url?.absoluteString == "https://api.github.com/user")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
    #expect(request.url?.query == nil)
    let gitlab = AuthenticationProfile(id: UUID(), provider: .gitlab, host: "git.example.invalid:8443", username: "fixture")
    let labRequest = try HostingAccountClient.request(gitlab, credential: GitStoredCredential(host: gitlab.host, username: "fixture", secret: "fixture-secret"))
    #expect(labRequest.url?.absoluteString == "https://git.example.invalid:8443/api/v4/user")
    #expect(labRequest.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "fixture-secret")
    #expect(labRequest.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(throws: GitFailure.self) { _ = try HostingAccountClient.request(github, credential: GitStoredCredential(host: "other.invalid", username: "fixture", secret: "fixture-secret")) }
    #expect(try HostingAccountClient.account(Data("{\"login\":\"fixture\"}".utf8)).login == "fixture")
    #expect(throws: GitFailure.self) { _ = try HostingAccountClient.account(Data("{}".utf8)) }
}

@Test @MainActor func networkHistoryKeepsTerminalStatusAndRecoversInterruptedOperations() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-network-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let activity = NetworkActivityStore(directory: directory), id = UUID(), cancellation = GitNetworkCancellation()
    func event(_ phase: GitNetworkEvent.Phase, _ output: String) -> GitNetworkEvent {
        GitNetworkEvent(id: id, command: "fetch", repository: "Fixture", started: Date(), phase: phase, output: output, cancellation: cancellation)
    }
    activity.receive(event(.running, "Starting"))
    #expect(activity.runningCount == 1)
    activity.cancel(id); #expect(cancellation.isCancelled)
    activity.receive(event(.succeeded, "Done"))
    activity.receive(event(.running, "Late progress"))
    #expect(activity.records.first?.phase == .succeeded && activity.records.first?.output == "Done")
    try await Task.sleep(for: .milliseconds(350))
    let restored = NetworkActivityStore(directory: directory)
    #expect(restored.records.first?.phase == .succeeded)
    let running = NetworkActivityRecord(id: UUID(), command: "push", repository: "Fixture", started: Date(), phase: .running, output: "Pending")
    try JSONEncoder().encode([running]).write(to: activity.file)
    let interrupted = NetworkActivityStore(directory: directory)
    #expect(interrupted.runningCount == 0 && interrupted.records.first?.phase == .failed)
    #expect(interrupted.records.first?.output.contains("Inspect the repository") == true)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_VERIFY_KEYCHAIN_HELPER"] == "1", "Explicit noninteractive temporary Keychain credential only."))
@MainActor func actualCredentialHelperReadsAndDeletesItsOwnTemporaryKeychainItem() async throws {
    let f = try await PreviewFixture.make(commits: 1, branches: 1); defer { f.clean() }
    let id = UUID(), host = "gitpico-keychain-test.invalid", secret = "fixture-" + UUID().uuidString
    try GitCredentialVault.save(GitStoredCredential(host: host, username: "fixture", secret: secret), id: id)
    defer { try? GitCredentialVault.remove(id) }
    let rotated = secret + "-rotated"
    try GitCredentialVault.save(GitStoredCredential(host: host, username: "fixture", secret: rotated), id: id)
    let executable = try #require(Bundle.main.executablePath)
    let reference = GitCredentialReference(id: id, host: host, executable: executable)
    let context = GitNetworkContext(credential: reference) { _ in }
    let output = try await GitNetworkContexts.$current.withValue(context) {
        try await GitProcess.run(["credential", "fill"], at: f.repository.root, input: Data("protocol=https\nhost=gitpico-keychain-test.invalid\n\n".utf8))
    }
    #expect(output.text.contains("username=fixture\n"))
    #expect(output.text.contains("password=" + rotated + "\n"))
    try GitCredentialVault.remove(id)
    #expect(throws: GitFailure.self) { _ = try GitCredentialVault.read(id) }
}
