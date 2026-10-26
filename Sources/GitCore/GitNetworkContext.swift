import Foundation
import Synchronization

public final class GitNetworkCancellation: Sendable {
    private let cancelled = Mutex(false)
    public init() {}
    public func cancel() { cancelled.withLock { $0 = true } }
    public var isCancelled: Bool { cancelled.withLock { $0 } }
}
public struct GitNetworkEvent: Sendable {
    public enum Phase: String, Codable, Sendable { case running, succeeded, failed, cancelled }
    public let id: UUID
    public let command: String
    public let repository: String
    public let repositoryPath: String?
    public let started: Date
    public let phase: Phase
    public let output: String
    public let cancellation: GitNetworkCancellation
    public init(id: UUID, command: String, repository: String, repositoryPath: String? = nil, started: Date, phase: Phase, output: String, cancellation: GitNetworkCancellation) {
        self.id = id; self.command = command; self.repository = repository; self.started = started; self.phase = phase; self.output = output; self.cancellation = cancellation
        self.repositoryPath = repositoryPath
    }
}
public struct GitNetworkContext: Sendable {
    public let credential: GitCredentialReference?
    public let nonInteractive: Bool
    public let sshCommand: String?
    public let observer: @Sendable (GitNetworkEvent) -> Void
    public init(credential: GitCredentialReference? = nil, nonInteractive: Bool = false, sshCommand: String? = nil, observer: @escaping @Sendable (GitNetworkEvent) -> Void) {
        self.credential = credential; self.nonInteractive = nonInteractive; self.sshCommand = sshCommand; self.observer = observer
    }
}
public enum GitNetworkContexts {
    @TaskLocal public static var current: GitNetworkContext?
    private struct Entry: Sendable { let owner: UUID; let context: GitNetworkContext }
    private static let values = Mutex<[String: Entry]>([:])
    public static func register(_ context: GitNetworkContext, root: URL, owner: UUID) { values.withLock { $0[root.standardizedFileURL.path] = Entry(owner: owner, context: context) } }
    public static func remove(root: URL, owner: UUID) { values.withLock { if $0[root.standardizedFileURL.path]?.owner == owner { $0.removeValue(forKey: root.standardizedFileURL.path) } } }
    static func context(at root: URL) -> GitNetworkContext? { current ?? values.withLock { $0[root.standardizedFileURL.path]?.context } }
}
public enum GitLogRedaction {
    public static func clean(_ text: String, secrets: [String] = []) -> String {
        var value = text
        for secret in secrets where !secret.isEmpty { value = value.replacingOccurrences(of: secret, with: "[redacted]") }
        for pattern in ["[A-Za-z][A-Za-z0-9+.-]*://[^\\s]+", "(?:gh[pousr]_|github_pat_|glpat-|sk-)[A-Za-z0-9_-]*", "(?i)\\b[0-9a-f]{64}\\b", "(?i)(?:authorization|proxy-authorization)\\s*[:=][^\\r\\n]*", "(?i)(?:password|access_token|refresh_token|device_code|code_verifier|private-token)\\s*[:=]\\s*[^\\s]+"] {
            if let regex = try? NSRegularExpression(pattern: pattern) { value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[redacted]") }
        }
        return String(value.suffix(32_768)).replacingOccurrences(of: "\r", with: "\n")
    }
}
final class GitNetworkObservation {
    let context: GitNetworkContext
    let id = UUID(), started = Date()
    let command: String
    let repository: String
    let repositoryPath: String?
    let cancellation = GitNetworkCancellation()
    private var secrets: [String]
    private var lastOutput = ""
    private var finished = false
    private var nextCredentialCheck = Date.distantPast
    init?(arguments: [String], context: GitNetworkContext?, root: URL) {
        var index = 0
        while index < arguments.count, arguments[index] == "-c", index + 1 < arguments.count { index += 2 }
        guard let context, index < arguments.count, ["fetch", "push", "pull", "clone", "ls-remote", "lfs", "submodule"].contains(arguments[index]) else { return nil }
        let command = arguments[index]
        let subcommand = index + 1 < arguments.count ? arguments[index + 1] : ""
        if command == "lfs", !["fetch", "pull", "push", "clone"].contains(subcommand) { return nil }
        if command == "submodule", !["add", "update"].contains(subcommand) { return nil }
        self.context = context; self.command = ["lfs", "submodule"].contains(command) ? command + " " + subcommand : command
        repository = command == "clone" ? URL(fileURLWithPath: arguments.last ?? root.path).lastPathComponent : root.lastPathComponent
        repositoryPath = command == "clone" ? nil : root.path
        secrets = context.credential.flatMap { try? GitCredentialVault.read($0.id) }.map { [$0.secret, $0.oauth?.refreshToken ?? ""] } ?? []
        send(.running, output: "Starting " + command + "…")
    }
    func prepareCredential() throws {
        // Git invokes the exact-host helper only if this transport actually needs
        // that HTTPS account. An expired HTTPS profile must not block SSH/other hosts.
        if cancellation.isCancelled { throw GitFailure("Network operation cancelled before Git started.") }
    }
    func progress(stdout: URL, stderr: URL) {
        if Date() >= nextCredentialCheck {
            if let id = context.credential?.id, let value = try? GitCredentialVault.read(id) {
                for secret in [value.secret, value.oauth?.refreshToken ?? ""] where !secret.isEmpty && !secrets.contains(secret) { secrets.append(secret) }
            }
            nextCredentialCheck = Date().addingTimeInterval(1)
        }
        func tail(_ url: URL) -> String {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
            return String(decoding: (try? handle.read(upToCount: 65_536)) ?? Data(), as: UTF8.self)
        }
        let value = GitLogRedaction.clean(tail(stdout) + "\n" + tail(stderr), secrets: secrets)
        if value != lastOutput { lastOutput = value; send(.running, output: value) }
    }
    func finish(succeeded: Bool, message: String = "") {
        guard !finished else { return }; finished = true
        send(cancellation.isCancelled ? .cancelled : succeeded ? .succeeded : .failed, output: lastOutput + (message.isEmpty ? "" : "\n" + GitLogRedaction.clean(message, secrets: secrets)))
    }
    private func send(_ phase: GitNetworkEvent.Phase, output: String) {
        context.observer(GitNetworkEvent(id: id, command: command, repository: repository, repositoryPath: repositoryPath, started: started, phase: phase, output: output, cancellation: cancellation))
    }
}
