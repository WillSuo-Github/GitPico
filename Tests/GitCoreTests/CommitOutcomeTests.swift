import Foundation
import Testing
@testable import GitCore

@Test func createdCommitIsNotReportedAsFailureWhenUndoStorageFails() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let old = try await f.repo.headPosition()
    try FileManager.default.createDirectory(at: f.url.appendingPathComponent(".git/gitpico/undo.json"), withIntermediateDirectories: true)
    try f.write("readme.txt", "committed content\n")
    try await f.git(["add", "readme.txt"])
    let outcome = try await f.repo.commit(message: "Created despite journal failure")
    #expect(outcome.undoWarning?.contains("commit was created") == true)
    #expect(try await f.repo.headPosition() != old)
    #expect(try await f.git(["show", "HEAD:readme.txt"]).text == "committed content\n")
    #expect(try await f.git(["status", "--porcelain"]).text.isEmpty)
}
