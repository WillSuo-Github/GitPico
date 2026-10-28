import Darwin
import Foundation

public struct SSHManagedKey: Identifiable, Sendable {
    public var id: String { publicFile.path }
    public let publicFile: URL
    public let privateFile: URL
    public let publicKey: String
    public let fingerprint: String
    public let managed: Bool
}
public struct SSHKeyManager: Sendable {
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")) { self.directory = directory }
    private var managedDirectory: URL { directory.appendingPathComponent("gitpico", isDirectory: true) }
    public func keys() async throws -> [SSHManagedKey] {
        var result: [SSHManagedKey] = []
        for folder in [directory, managedDirectory] {
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "pub" }).sorted(by: { $0.path < $1.path }) {
                guard result.count < 100 else { throw GitFailure("SSH key list exceeds its 100-key limit.") }
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 16_384 else { continue }
                let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                guard ["ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-", "sk-ssh-", "sk-ecdsa-"].contains(where: { text.hasPrefix($0) }), !text.contains("\n") else { continue }
                let fingerprint = try await tool("/usr/bin/ssh-keygen", ["-l", "-f", file.path])
                result.append(SSHManagedKey(publicFile: file, privateFile: file.deletingPathExtension(), publicKey: text, fingerprint: fingerprint, managed: folder == managedDirectory))
            }
        }
        return result
    }
    public func generate(name: String, comment: String) async throws -> SSHManagedKey {
        guard !name.isEmpty, name.count <= 64, name.first?.isLetter == true,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              comment.utf8.count <= 256, !comment.contains(where: { $0.isNewline || $0 == "\0" }) else { throw GitFailure("Use a key name beginning with a letter and containing only ASCII letters, digits, hyphens or underscores.") }
        for folder in [directory, managedDirectory] {
            if FileManager.default.fileExists(atPath: folder.path) {
                guard try FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType == .typeDirectory else { throw GitFailure("SSH key storage must be a real directory, not a symbolic link.") }
            } else { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        }
        let file = managedDirectory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: file.path + ".pub") else { throw GitFailure("A key with this name already exists. Existing keys are never overwritten.") }
        _ = try await tool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", file.path])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard let result = try await keys().first(where: { $0.privateFile.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path }) else { throw GitFailure("The generated key could not be inspected.") }
        return result
    }
    public func addToAgent(_ key: SSHManagedKey) async throws {
        guard FileManager.default.fileExists(atPath: key.privateFile.path), try await keys().contains(where: { $0.id == key.id && $0.fingerprint == key.fingerprint }) else { throw GitFailure("The selected key changed. Reload SSH keys.") }
        _ = try await tool("/usr/bin/ssh-add", [key.privateFile.path])
    }
    private func tool(_ executable: String, _ arguments: [String]) async throws -> String {
        try await Task.detached { try Self.execute(executable, arguments) }.value
    }
    private static func execute(_ executable: String, _ arguments: [String]) throws -> String {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS_REQUIRE"] = "never"; environment["DISPLAY"] = nil
            process.environment = environment
            let completed = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in completed.signal() }
            try process.run()
            if completed.wait(timeout: .now() + 15) == .timedOut {
                process.terminate()
                if completed.wait(timeout: .now() + 1) == .timedOut { Darwin.kill(process.processIdentifier, SIGKILL); _ = completed.wait(timeout: .now() + 1) }
                throw GitFailure("SSH command timed out. Unlock encrypted keys using your system SSH agent, then retry.")
            }
            let text = String(decoding: (try output.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            let failure = String(decoding: (try errors.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            guard process.terminationStatus == 0 else { throw GitFailure("SSH command failed. \(GitLogRedaction.clean(failure)) Unlock encrypted keys using your system SSH agent when needed.") }
            return String(text.prefix(32_768)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
