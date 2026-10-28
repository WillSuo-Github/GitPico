import Foundation

public struct GitFailure: LocalizedError, Sendable {
    enum Reason: Sendable { case outputLimitExceeded }
    public let message: String
    let reason: Reason?
    public var errorDescription: String? { message }
    /// User-facing messages are localized from GitCore's string catalog.
    public init(_ message: String.LocalizationValue) { self.message = localized(message); reason = nil }
    init(_ message: String.LocalizationValue, reason: Reason) { self.message = localized(message); self.reason = reason }
    /// Text that must not be translated, such as Git's own output.
    public init(verbatim message: String) { self.message = message; reason = nil }
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
        let trace = GitCommandTrace.current, phase = GitCommandTrace.phase, started = ContinuousClock.now
        let networkContext = GitNetworkContexts.context(at: root)
        let worker = Task.detached(priority: .userInitiated) {
            try execute(arguments, root: root, allowed: allowed, timeout: timeout, acceptGeneratedMessage: acceptGeneratedMessage, sequenceEditor: sequenceEditor, input: input, identityEnvironment: identityEnvironment, indexFile: indexFile, maxOutputBytes: maxOutputBytes, lfsEnvironment: lfsEnvironment, cancellable: cancellable, networkContext: networkContext)
        }
        // Write operations retain their existing finish-current-step semantics.
        do {
            let result: GitOutput
            if cancellable { result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() } }
            else { result = try await worker.value }
            await trace?.record(command: arguments.first ?? "unknown", phase: phase, elapsed: started.duration(to: .now), failed: false)
            return result
        } catch {
            await trace?.record(command: arguments.first ?? "unknown", phase: phase, elapsed: started.duration(to: .now), failed: true)
            throw error
        }
    }

    private static func execute(_ arguments: [String], root: URL, allowed: Set<Int32>, timeout: TimeInterval, acceptGeneratedMessage: Bool, sequenceEditor: URL?, input: Data?, identityEnvironment: [String: String], indexFile: URL?, maxOutputBytes: Int, lfsEnvironment: [String: String], cancellable: Bool, networkContext: GitNetworkContext?) throws -> GitOutput {
            if cancellable { try Task.checkCancellation() }
            let network = GitNetworkObservation(arguments: arguments, context: networkContext, root: root)
            defer { network?.finish(succeeded: false, message: localized("Git did not finish successfully. Review the output before retrying.")) }
            try network?.prepareCredential()
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
            let authentication = (networkContext?.nonInteractive == true ? ["-c", "credential.helper="] : []) + (networkContext?.credential.map { ["-c", "credential.https://" + $0.host + ".helper=", "-c", "credential.https://" + $0.host + ".helper=" + $0.helper] } ?? [])
            var commandArguments = arguments
            if network != nil {
                var index = 0
                while index + 1 < commandArguments.count, commandArguments[index] == "-c" { index += 2 }
                if index < commandArguments.count, ["fetch", "pull", "push", "clone"].contains(commandArguments[index]), !commandArguments.contains("--progress") {
                    commandArguments.insert("--progress", at: index + 1)
                }
            }
            process.arguments = ["--no-pager"] + pathOptions + ["-c", "color.ui=false"] + authentication + commandArguments
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
            if network != nil {
                for key in ["GIT_TRACE", "GIT_TRACE_PACKET", "GIT_TRACE_CURL", "GIT_CURL_VERBOSE"] { environment.removeValue(forKey: key) }
                environment["GIT_TRACE_REDACT"] = "1"
            }
            if networkContext?.nonInteractive == true {
                environment["GIT_ASKPASS"] = "/usr/bin/false"; environment["SSH_ASKPASS"] = "/usr/bin/false"
                environment["SSH_ASKPASS_REQUIRE"] = "never"; environment["GCM_INTERACTIVE"] = "Never"
                environment["GIT_SSH_COMMAND"] = (networkContext?.sshCommand ?? "/usr/bin/ssh") + " -o BatchMode=yes -o StrictHostKeyChecking=yes"
            }
            if let credential = networkContext?.credential {
                environment["GITPICO_CREDENTIAL_ID"] = credential.id.uuidString
                environment["GITPICO_CREDENTIAL_HOST"] = credential.host
            }
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
            let completion = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in completion.signal() }
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            let completed: Bool
            if cancellable || network != nil {
                var exited = false
                var nextProgress = ContinuousClock.now
                while !(cancellable && Task.isCancelled) && network?.cancellation.isCancelled != true && ContinuousClock.now < deadline {
                    if completion.wait(timeout: .now() + .milliseconds(10)) == .success { exited = true; break }
                    if ContinuousClock.now >= nextProgress {
                        network?.progress(stdout: outURL, stderr: errURL)
                        nextProgress = ContinuousClock.now.advanced(by: .milliseconds(100))
                    }
                }
                completed = exited
            } else {
                completed = completion.wait(timeout: .now() + timeout) == .success
            }
            if !completed {
                if process.isRunning { process.terminate() }
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.025) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                network?.progress(stdout: outURL, stderr: errURL)
                if network?.cancellation.isCancelled == true { throw GitFailure("Network operation cancelled. The server or working copy may already have changed; review the refreshed state before retrying.") }
                if cancellable && Task.isCancelled { network?.cancellation.cancel(); throw CancellationError() }
                throw GitFailure("Git timed out after \(Int(timeout)) seconds. Check SSH, signing, hooks, or network access.")
            }
            // The termination callback already observed exit; waitUntilExit would pump
            // Foundation's run loop and add latency to every short command.
            if cancellable { try Task.checkCancellation() }
            let reader = try FileHandle(forReadingFrom: outURL)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: maxOutputBytes + 1) ?? Data()
            guard data.count <= maxOutputBytes else { throw GitFailure("Git output exceeds \(maxOutputBytes / 1024 / 1024) MB. Narrow the selection before trying again.", reason: .outputLimitExceeded) }
            let errorReader = try FileHandle(forReadingFrom: errURL)
            defer { try? errorReader.close() }
            let error = String(decoding: try errorReader.read(upToCount: 64 * 1024) ?? Data(), as: UTF8.self)
            let result = GitOutput(data: data, error: error, status: process.terminationStatus)
            network?.progress(stdout: outURL, stderr: errURL)
            network?.finish(succeeded: allowed.contains(result.status))
            guard allowed.contains(result.status) else {
                let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
                // Git's own diagnostics are shown untranslated.
                throw message.isEmpty ? GitFailure("Git exited with status \(result.status).") : GitFailure(verbatim: message)
            }
            return result
    }

    public static func extensionSearchPath(_ inherited: String?) -> String {
        var paths = (inherited ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        for path in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !paths.contains(path) { paths.append(path) }
        return paths.joined(separator: ":")
    }
}
