import Foundation
import GitCore
import Testing
@testable import GitPico

@Test @MainActor func localChangeRoutesSelectionAndRejectsOldRepositoryRequests() async throws {
    let store = RepositoryStore()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-local-routing-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await GitProcess.run(["init", "-q", "-b", "main"], at: directory)
    store.repository = try await GitRepository.open(directory)
    try "one\n".write(to: directory.appendingPathComponent("one"), atomically: true, encoding: .utf8)
    try "two\n".write(to: directory.appendingPathComponent("two"), atomically: true, encoding: .utf8)
    store.snapshot = try await store.repository?.snapshot()
    store.selectedWorkingFiles = ["one", "two"]
    store.discardSelection("two")
    let request = try #require(store.localChangeRequest)
    guard case .discard(let paths) = request.action else { Issue.record("Expected discard request"); return }
    #expect(paths == ["one", "two"])
    let repo = try #require(store.repository)
    let plan = try await repo.previewDiscard(paths: paths, scope: .unstaged)
    store.repositoryToken = UUID()
    store.applyLocalPlan(plan, request: request)
    #expect(store.error?.contains("repository changed") == true)
    #expect(!store.isBusy)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("one").path))
    store.error = nil; store.isBusy = true; store.localChangeRequest = nil
    store.localChange(.recovery)
    #expect(store.localChangeRequest == nil)
}

@Test func exportedPatchWriterPreservesBytesAndExistingFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-patch-writer-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("exact.patch"), data = Data([0, 255, 13, 10, 128])
    try writeNewPatchFile(data, to: url)
    #expect(try Data(contentsOf: url) == data)
    #expect(throws: (any Error).self) { try writeNewPatchFile(Data("replacement".utf8), to: url) }
    #expect(try Data(contentsOf: url) == data)
}
