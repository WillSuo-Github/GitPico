import Foundation

extension GitRepository {
    public func observationPaths() async throws -> [String] {
        let git = try gitPathOutput(await GitProcess.run(["rev-parse", "--absolute-git-dir"], at: root))
        let common = try gitPathOutput(await GitProcess.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root))
        return Array(Set([root.path, git, common].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }))
    }
    public func observedSnapshot(from previous: RepositorySnapshot? = nil) async throws -> RepositorySnapshot {
        for _ in 0..<3 {
            let before = try await headPosition()
            let value = try await snapshot(countHistory: false, reusingHistoryFrom: previous)
            if value.head == before, try await headPosition() == before { return value }
        }
        throw GitFailure("The repository is changing in another application. Automatic refresh will retry on its next change.")
    }
}
