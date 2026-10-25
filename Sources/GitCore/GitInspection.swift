import Foundation

extension GitRepository {
    public func readIdentity() async throws -> GitIdentity {
        async let name = GitProcess.run(["config", "--get", "user.name"], at: root, allowed: [0, 1])
        async let email = GitProcess.run(["config", "--get", "user.email"], at: root, allowed: [0, 1])
        return try await GitIdentity(name: name.text.trimmingCharacters(in: .newlines), email: email.text.trimmingCharacters(in: .newlines))
    }

    public func currentOperation() async throws -> RepositoryOperation {
        let directory = URL(fileURLWithPath: try gitPathOutput(await GitProcess.run(["rev-parse", "--absolute-git-dir"], at: root)))
        for (path, operation) in [("rebase-merge", RepositoryOperation.rebase), ("rebase-apply", .rebase), ("MERGE_HEAD", .merge), ("CHERRY_PICK_HEAD", .cherryPick), ("REVERT_HEAD", .revert)] {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path) { return operation }
        }
        return .none
    }

    public func compare(_ branch: Reference, to base: String) async throws -> BranchComparison {
        let counts = try await GitProcess.run(["rev-list", "--left-right", "--count", branch.fullName + "..." + base, "--"], at: root)
        let values = counts.text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        let commits = try await GitProcess.run(["log", "--no-show-signature", "--max-count=500", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%D%x00", base + ".." + branch.fullName, "--"], at: root)
        let files = try await GitProcess.run(["diff", "--name-status", "-z", base + "..." + branch.fullName, "--"], at: root)
        return BranchComparison(branch: branch, ahead: values.first ?? 0, behind: values.last ?? 0, commits: GitParser.commits(commits.data), files: GitParser.changedPaths(files.data))
    }

    public func configuration() async throws -> RepositoryConfiguration {
        let remotes = try await remoteConfigurations()
        let descriptionURL = try await gitPath("description")
        let description = FileManager.default.fileExists(atPath: descriptionURL.path) ? try String(contentsOf: descriptionURL, encoding: .utf8) : ""
        let signing = try await GitProcess.run(["config", "--bool", "--get", "commit.gpgsign"], at: root, allowed: [0, 1]).text.trimmingCharacters(in: .newlines)
        let key = try await GitProcess.run(["config", "--get", "user.signingkey"], at: root, allowed: [0, 1]).text.trimmingCharacters(in: .newlines)
        return RepositoryConfiguration(identity: try await readIdentity(), remotes: remotes, description: description.trimmingCharacters(in: .newlines), signCommits: signing == "true", signingKey: key)
    }

    public func saveIdentity(name: String, email: String) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitFailure("Enter both a name and an email address.") }
        _ = try await GitProcess.run(["config", "--local", "user.name", name], at: root)
        _ = try await GitProcess.run(["config", "--local", "user.email", email], at: root)
    }

    public func saveConfiguration(name: String, email: String, description: String, signCommits: Bool, signingKey: String) async throws {
        try await saveIdentity(name: name, email: email)
        _ = try await GitProcess.run(["config", "--local", "commit.gpgsign", signCommits ? "true" : "false"], at: root)
        if signingKey.isEmpty { _ = try await GitProcess.run(["config", "--local", "--unset-all", "user.signingkey"], at: root, allowed: [0, 5]) }
        else { _ = try await GitProcess.run(["config", "--local", "user.signingkey", signingKey], at: root) }
        try Data((description + "\n").utf8).write(to: try await gitPath("description"), options: .atomic)
    }

    public enum IgnoreFile: String, Sendable, CaseIterable { case ignores = "Ignores", excludes = "Excludes" }
    public func ignoreFileURL(_ kind: IgnoreFile) async throws -> URL {
        switch kind { case .ignores: root.appendingPathComponent(".gitignore"); case .excludes: try await gitPath("info/exclude") }
    }

    public func readIgnoreFile(_ kind: IgnoreFile) async throws -> String {
        let url = try await ignoreFileURL(kind)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func writeIgnoreFile(_ kind: IgnoreFile, text: String, expected: String) async throws {
        guard try await readIgnoreFile(kind) == expected else { throw GitFailure("This file changed outside GitPico. Reload before saving.") }
        let url = try await ignoreFileURL(kind)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func gitPath(_ name: String) async throws -> URL {
        let path = try await GitProcess.run(["rev-parse", "--git-path", name], at: root).text.trimmingCharacters(in: .newlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    public func fileTree(at hash: String) async throws -> [String] {
        try await GitProcess.run(["ls-tree", "-r", "--name-only", "-z", hash, "--"], at: root).text.split(separator: "\0").map(String.init)
    }

    public func historicFile(at hash: String, path: String) async throws -> String {
        try validateInspectionPath(path)
        let commit = try await verifiedCommit(hash)
        let output = try await GitProcess.run(["cat-file", "blob", commit + ":" + path], at: root)
        guard !output.data.contains(0) else { return "Binary file — text preview unavailable." }
        return output.text
    }
}
