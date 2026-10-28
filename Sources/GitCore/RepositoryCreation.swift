import Foundation

extension GitRepository {
    public static func create(at destination: URL, source: String? = nil, recursive: Bool = false, allowLocalTransport: Bool = false, lfs: LFSCloneMode = .inherit) async throws -> GitRepository {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw GitFailure("The destination already exists. Choose a new folder name.") }
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else { throw GitFailure("Choose an existing parent directory.") }
        if let source {
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitFailure("Enter a repository URL or local path.") }
            let policy: [String]
            if recursive {
                let validator = GitRepository(root: parent)
                try await validator.validateModuleURL(source, allowLocal: allowLocalTransport)
                policy = await validator.moduleTransportOptions(allowLocalTransport)
            } else { policy = [] }
            if lfs != .inherit { try await GitRepository(root: parent).requireLFS() }
            let filters = lfs == .inherit ? [] : Self.lfsFilters.keys.sorted().flatMap { ["-c", $0 + "=" + Self.lfsFilters[$0]!] }
            do { _ = try await GitProcess.run(policy + ["clone"] + filters + (recursive ? ["--recurse-submodules"] : []) + ["--", source, destination.path], at: parent, timeout: 120, lfsEnvironment: lfs == .inherit ? [:] : ["GIT_LFS_SKIP_SMUDGE": lfs == .pointersOnly ? "1" : "0"]) }
            catch { throw GitFailure("\(error.localizedDescription)\nThe destination may contain a partial clone; existing files were kept. Open it to retry submodule initialization.") }
        } else {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            _ = try await GitProcess.run(["init", "-b", "main"], at: destination)
        }
        let repository = try await open(destination)
        if source != nil, lfs != .inherit {
            let hook = try await repository.lfsHookURL(), common = try await repository.commonDirectory()
            let noHook = try repository.localAttributes(hook) == nil
            let safeHook = hook.path.hasPrefix(common.path + "/hooks/") && noHook
            try await repository.applyLFSChange(try await repository.previewLFSChange(.enable(installHook: safeHook)))
        }
        return repository
    }
}
