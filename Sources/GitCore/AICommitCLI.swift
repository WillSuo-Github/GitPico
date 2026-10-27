import Foundation

public enum AICommitProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, antigravity, copilot
    public var id: String { rawValue }
    public var title: String {
        switch self { case .codex: "Codex CLI"; case .claude: "Claude Code"; case .antigravity: "Antigravity (agy)"; case .copilot: "GitHub Copilot CLI" }
    }
    public var command: String { self == .antigravity ? "agy" : rawValue }
    public static var searchPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return GitProcess.extensionSearchPath(ProcessInfo.processInfo.environment["PATH"]) + ":" + ["/.local/bin", "/.npm-global/bin", "/.volta/bin", "/.bun/bin"].map { home + $0 }.joined(separator: ":")
    }
    public func executable(override: String = "") -> URL? {
        let path = override.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = path.isEmpty ? Self.searchPath.split(separator: ":").map { String($0) + "/" + command } : [(path as NSString).expandingTildeInPath]
        return candidates.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    func invocation(prompt: String) -> (arguments: [String], input: Data?) {
        switch self {
        case .codex:
            return (["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--disable", "shell_tool", "--disable", "hooks", "--color", "never", "-c", "approval_policy=\"never\"", "-"], Data(prompt.utf8))
        case .claude:
            return (["--print", "--output-format", "text", "--tools", "", "--strict-mcp-config", "--setting-sources", "user", "--settings", "{\"disableAllHooks\":true}", "--no-session-persistence", "--disable-slash-commands"], Data(prompt.utf8))
        case .antigravity:
            return (["--print", prompt, "--output-format", "text", "--sandbox", "--disable-slash-commands", "--print-timeout", "120s"], nil)
        case .copilot:
            return (["--prompt", prompt, "--silent", "--stream", "off", "--no-color", "--deny-tool=shell", "--deny-tool=write", "--disable-builtin-mcps", "--no-custom-instructions", "--no-ask-user", "--no-auto-update"], nil)
        }
    }
}

public struct AICommitMessage: Codable, Equatable, Sendable {
    public var summary: String
    public var body: String
    public init(summary: String, body: String) { self.summary = summary; self.body = body }
    public static func parse(_ output: String) throws -> Self {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8), var result = try? JSONDecoder().decode(Self.self, from: data) else {
            throw GitFailure("The CLI did not return a commit message. Check its login and model configuration, then try again.")
        }
        result.summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        result.body = result.body.trimmingCharacters(in: .whitespacesAndNewlines)
        try result.validate()
        return result
    }
    public func validate() throws {
        guard !summary.isEmpty, summary.count <= 300, !summary.contains(where: \.isNewline), body.utf8.count <= 32 * 1024,
              !(summary + body).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
            throw GitFailure("Use a single-line summary up to 300 characters and a description up to 32 KB.")
        }
    }
}

public protocol AICommitGenerating: Sendable {
    func generate(provider: AICommitProvider, executable: URL, prompt: String) async throws -> AICommitMessage
}
public struct AICommitCLI: AICommitGenerating {
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 120) { self.timeout = timeout }
    public func generate(provider: AICommitProvider, executable: URL, prompt: String) async throws -> AICommitMessage {
        let timeout = timeout
        let worker = Task.detached(priority: .userInitiated) {
            try Self.execute(provider: provider, executable: executable, prompt: prompt, timeout: timeout)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private static func execute(provider: AICommitProvider, executable: URL, prompt: String, timeout: TimeInterval) throws -> AICommitMessage {
        try Task.checkCancellation()
        guard prompt.utf8.count <= 128 * 1024 else { throw GitFailure("The AI request is too large. Stage fewer changes.") }
        let fm = FileManager.default, directory = fm.temporaryDirectory.appendingPathComponent("GitPico-AI-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let invocation = provider.invocation(prompt: prompt)
        let outURL = directory.appendingPathComponent("stdout"), errURL = directory.appendingPathComponent("stderr"), inputURL = directory.appendingPathComponent("stdin")
        for url in [outURL, errURL, inputURL] { fm.createFile(atPath: url.path, contents: url == inputURL ? invocation.input : nil, attributes: [.posixPermissions: 0o600]) }
        let output = try FileHandle(forWritingTo: outURL), errors = try FileHandle(forWritingTo: errURL), input = try FileHandle(forReadingFrom: inputURL)
        defer { try? output.close(); try? errors.close(); try? input.close() }
        let process = Process(); process.executableURL = executable; process.arguments = invocation.arguments; process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") || ["PWD", "OLDPWD"].contains(key) { environment.removeValue(forKey: key) }
        environment["PATH"] = AICommitProvider.searchPath; environment["NO_COLOR"] = "1"
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var completed = false, oversized = false
        while !Task.isCancelled && Date() < deadline {
            if completion.wait(timeout: .now() + .milliseconds(25)) == .success { completed = true; break }
            if [outURL, errURL].contains(where: { ((try? fm.attributesOfItem(atPath: $0.path)[.size]) as? NSNumber)?.intValue ?? 0 > 1024 * 1024 }) { oversized = true; break }
        }
        if !completed {
            if process.isRunning { process.terminate() }
            if completion.wait(timeout: .now() + 1) != .success, process.isRunning { kill(process.processIdentifier, SIGKILL); _ = completion.wait(timeout: .now() + 1) }
            try Task.checkCancellation()
            throw GitFailure(oversized ? "The CLI returned too much output. Check its configuration." : "AI generation timed out. Check the CLI's login and model, then try again.")
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            // CLI diagnostics can echo the diff or credentials. Keep them out of persistent logs and UI.
            throw GitFailure("\(provider.title) exited with status \(process.terminationStatus). Sign in and check its model configuration in Terminal, then try again.")
        }
        let handle = try FileHandle(forReadingFrom: outURL); defer { try? handle.close() }
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024 else { throw GitFailure("The CLI returned too much output. Check its configuration.") }
        return try AICommitMessage.parse(String(decoding: data, as: UTF8.self))
    }
}
