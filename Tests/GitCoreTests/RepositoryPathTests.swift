import Foundation
import Testing
@testable import GitCore

@Test func openRepositoryPreservesTrailingNewlineInsteadOfOpeningSibling() async throws {
    let sibling = try await Fixture.make(); defer { sibling.clean() }
    let requested = URL(fileURLWithPath: sibling.url.path + "\n", isDirectory: true)
    try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: requested) }
    _ = try await GitProcess.run(["init", "-q", "-b", "requested"], at: requested)
    let repository = try await GitRepository.open(requested)
    #expect(await repository.root.path == requested.resolvingSymlinksInPath().path)
    let snapshot = try await repository.snapshot()
    #expect(snapshot.branch == "requested" && !snapshot.hasHEAD)
    #expect(try await sibling.repo.snapshot().branch == "main")
}
