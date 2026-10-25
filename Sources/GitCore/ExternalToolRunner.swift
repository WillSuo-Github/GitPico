import Foundation

public struct ExternalToolStatus: Sendable {
    public let running: Bool
    public let exitCode: Int32?
    public let diagnostics: String
}

public actor ExternalToolRunner {
    private var processes: [UUID: Process] = [:]
    private var diagnostics: [UUID: URL] = [:]
    public init() {}
    public func launch(_ command: ExternalToolCommand, session: ExternalToolSession, files: [String: URL]) throws {
        guard processes[session.id]?.isRunning != true else { throw GitFailure("This session's tool is already running.") }
        guard FileManager.default.isExecutableFile(atPath: command.executable) else { throw GitFailure("The tool executable is missing or not executable. Check External Tools settings.") }
        guard !session.applied else { throw GitFailure("This merge result was already applied.") }
        for url in files.values {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw GitFailure("A session file was replaced with a link or non-file. Reopen the session.") }
        }
        let arguments = try command.invocation(files: files, merge: session.isMerge)
        guard let merged = files["merged"] else { throw GitFailure("Missing session output.") }
        let directory = merged.deletingLastPathComponent().deletingLastPathComponent()
        let log = directory.appendingPathComponent("tool-output.log")
        if FileManager.default.fileExists(atPath: log.path) { try FileManager.default.removeItem(at: log) }
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log); defer { try? output.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = arguments; process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
        try process.run(); processes[session.id] = process; diagnostics[session.id] = log
    }
    public func status(_ id: UUID) -> ExternalToolStatus {
        let process = processes[id], running = process?.isRunning == true
        var output = ""
        if let url = diagnostics[id], let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            output = String(decoding: (try? handle.read(upToCount: 64 * 1024)) ?? Data(), as: UTF8.self)
        }
        return ExternalToolStatus(running: running, exitCode: running ? nil : process?.terminationStatus, diagnostics: output)
    }
}
