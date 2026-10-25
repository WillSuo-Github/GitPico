import Foundation

public struct GitFailure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct GitOutput: Sendable {
    public let data: Data
    public let error: String
    public let status: Int32
    public var text: String { String(decoding: data, as: UTF8.self) }
}

// A worker thread owns each Process. Temporary files avoid pipe-buffer deadlocks.
public enum GitProcess {
    public static func run(_ arguments: [String], at root: URL, allowed: Set<Int32> = [0], timeout: TimeInterval = 30, acceptGeneratedMessage: Bool = false, sequenceEditor: URL? = nil, input: Data? = nil, identityEnvironment: [String: String] = [:], indexFile: URL? = nil, maxOutputBytes: Int = 16 * 1024 * 1024, lfsEnvironment: [String: String] = [:], cancellable: Bool = false) async throws -> GitOutput {
        if cancellable { try Task.checkCancellation() }
        guard (1...128 * 1024 * 1024).contains(maxOutputBytes) else { throw GitFailure("Invalid Git output limit.") }
        let worker = Task.detached(priority: .userInitiated) {
            try execute(arguments, root: root, allowed: allowed, timeout: timeout, acceptGeneratedMessage: acceptGeneratedMessage, sequenceEditor: sequenceEditor, input: input, identityEnvironment: identityEnvironment, indexFile: indexFile, maxOutputBytes: maxOutputBytes, lfsEnvironment: lfsEnvironment, cancellable: cancellable)
        }
        // Write operations retain their existing finish-current-step semantics.
        guard cancellable else { return try await worker.value }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func execute(_ arguments: [String], root: URL, allowed: Set<Int32>, timeout: TimeInterval, acceptGeneratedMessage: Bool, sequenceEditor: URL?, input: Data?, identityEnvironment: [String: String], indexFile: URL?, maxOutputBytes: Int, lfsEnvironment: [String: String], cancellable: Bool) throws -> GitOutput {
            if cancellable { try Task.checkCancellation() }
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent("GitPico-process-\(UUID().uuidString)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: directory) }
            let outURL = directory.appendingPathComponent("stdout")
            let errURL = directory.appendingPathComponent("stderr")
            fm.createFile(atPath: outURL.path, contents: nil)
            fm.createFile(atPath: errURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outURL)
            let errors = try FileHandle(forWritingTo: errURL)
            defer { try? output.close(); try? errors.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = root
            // Do not leak literal-pathspec mode into compound operations such as stash:
            // Apple Git 2.54 leaves untracked files behind during stash cleanup in that mode.
            let pathCommands = ["status", "diff", "diff-tree", "show", "log", "blame", "add", "rm", "restore", "ls-files", "ls-tree"]
            let pathOptions = pathCommands.contains(arguments.first ?? "") ? ["--literal-pathspecs"] : []
            process.arguments = ["--no-pager"] + pathOptions + ["-c", "color.ui=false"] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = extensionSearchPath(environment["PATH"])
            for (key, value) in lfsEnvironment {
                guard ["GIT_LFS_SKIP_SMUDGE", "GIT_LFS_PROGRESS", "GIT_LFS_FORCE_PROGRESS"].contains(key) else { throw GitFailure("Unsupported LFS process environment option.") }
                environment[key] = value
            }
            for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"] { environment.removeValue(forKey: key) }
            // Only explicitly owned scratch indexes may override the process index.
            if let indexFile { environment["GIT_INDEX_FILE"] = indexFile.path }
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            environment["GIT_PAGER"] = "cat"
            environment["GIT_EDITOR"] = acceptGeneratedMessage ? "/usr/bin/true" : "/usr/bin/false"
            environment["GIT_SEQUENCE_EDITOR"] = sequenceEditor.map { shellQuote($0.path) } ?? "/usr/bin/false"
            environment["LC_ALL"] = "en_US.UTF-8"
            for key in ["GIT_AUTHOR_DATE", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_DATE", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"] {
                if let value = identityEnvironment[key] { environment[key] = value }
            }
            process.environment = environment
            var inputHandle: FileHandle?
            if let input {
                let url = directory.appendingPathComponent("stdin")
                try input.write(to: url)
                inputHandle = try FileHandle(forReadingFrom: url)
                process.standardInput = inputHandle
            } else { process.standardInput = FileHandle.nullDevice }
            defer { try? inputHandle?.close() }
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline && !(cancellable && Task.isCancelled) { Thread.sleep(forTimeInterval: cancellable ? 0.01 : 0.025) }
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.025) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if cancellable && Task.isCancelled { throw CancellationError() }
                throw GitFailure("Git timed out after \(Int(timeout)) seconds. Check SSH, signing, hooks, or network access.")
            }
            process.waitUntilExit()
            if cancellable { try Task.checkCancellation() }
            let reader = try FileHandle(forReadingFrom: outURL)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: maxOutputBytes + 1) ?? Data()
            guard data.count <= maxOutputBytes else { throw GitFailure("Git output exceeds \(maxOutputBytes / 1024 / 1024) MB. Narrow the selection before trying again.") }
            let errorReader = try FileHandle(forReadingFrom: errURL)
            defer { try? errorReader.close() }
            let error = String(decoding: try errorReader.read(upToCount: 64 * 1024) ?? Data(), as: UTF8.self)
            let result = GitOutput(data: data, error: error, status: process.terminationStatus)
            guard allowed.contains(result.status) else {
                throw GitFailure(error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Git exited with status \(result.status)." : error.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return result
    }

    public static func extensionSearchPath(_ inherited: String?) -> String {
        var paths = (inherited ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        for path in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !paths.contains(path) { paths.append(path) }
        return paths.joined(separator: ":")
    }
}
