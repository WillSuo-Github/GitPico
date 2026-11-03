import Foundation

public struct FetchOptions: Sendable {
    public enum Tags: String, CaseIterable, Sendable { case configured, skip, all }
    public enum TimeLimit: Int, CaseIterable, Sendable {
        case short = 5, standard = 30, extended = 120
        var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    }

    public var branch: String?
    public var prune = false
    public var tags: Tags = .configured
    public var recurseSubmodules = false
    public var useHTTP11 = false
    public var timeLimit: TimeLimit = .standard

    public init() {}
}

extension GitRepository {
    public func fetch(_ remote: RemoteConfiguration?, options: FetchOptions) async throws {
        if let remote { try await requireRemote(remote) }
        var arguments = options.useHTTP11 ? ["-c", "http.version=HTTP/1.1"] : []
        arguments += ["fetch", options.recurseSubmodules ? "--recurse-submodules=on-demand" : "--no-recurse-submodules"]
        if options.prune && options.branch == nil { arguments += ["--prune", "--no-prune-tags"] }
        else { arguments.append("--no-prune") }
        switch options.tags {
        case .configured: break
        case .skip: arguments.append("--no-tags")
        case .all: arguments.append("--tags")
        }
        if let branch = options.branch {
            guard let remote else { throw GitFailure("Choose one remote to fetch a single branch.") }
            let ref = "refs/heads/" + branch
            _ = try await GitProcess.run(["check-ref-format", ref], at: root)
            // Git's configured refmap can update a tracking ref for this branch;
            // leave custom refspecs intact and never write a local branch here.
            arguments += ["--no-all", "--", remote.name, ref]
        } else if let remote {
            arguments += ["--no-all", "--", remote.name]
        } else {
            arguments.append("--all")
        }
        _ = try await GitProcess.run(arguments, at: root, timeout: options.timeLimit.seconds)
    }
}
