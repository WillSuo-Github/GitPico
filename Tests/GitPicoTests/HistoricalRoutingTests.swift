import Foundation
import GitCore
import Testing
@testable import GitPico

@Test @MainActor func historicalRequestsRetainSelectionRevisionAndRepositorySession() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-historical-routing-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await GitProcess.run(["init", "-q", "-b", "main"], at: directory)
    let store = RepositoryStore(); store.repository = try await GitRepository.open(directory)
    try "source\n".write(to: directory.appendingPathComponent("source"), atomically: true, encoding: .utf8)
    _ = try await GitProcess.run(["add", "."], at: directory)
    _ = try await GitProcess.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Source"], at: directory)
    let repository = try #require(store.repository), hash = try #require(try await repository.headPosition().hash)
    store.historical(.restore("renamed"), revision: hash, paths: ["source"])
    let request = try #require(store.historicalRequest)
    #expect(request.revision == hash && request.paths == ["source"])
    guard case .restore(let destination) = request.action else { Issue.record("Expected restore request"); return }
    #expect(destination == "renamed")
    let snapshot = try await repository.historicalSnapshot(revision: hash, paths: request.paths)
    let plan = try await repository.previewHistoricalRestore(snapshot, destination: "renamed")
    store.repositoryToken = UUID()
    store.applyHistoricalPlan(plan, request: request)
    #expect(store.error?.contains("repository changed") == true)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("renamed").path))
    store.historicalRequest = nil; store.isBusy = true
    store.historical(.archive, revision: hash)
    #expect(store.historicalRequest == nil)
}

@Test @MainActor func historicalStoreExportsFrozenSnapshotInBackgroundWithoutWindows() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-historical-store-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await GitProcess.run(["init", "-q", "-b", "main"], at: directory)
    try Data([0, 255, 128]).write(to: directory.appendingPathComponent("file"))
    _ = try await GitProcess.run(["add", "."], at: directory)
    _ = try await GitProcess.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Source"], at: directory)
    let repository = try await GitRepository.open(directory), snapshot = try await repository.historicalSnapshot(revision: "HEAD")
    let store = RepositoryStore(), output = directory.appendingPathComponent("result")
    store.writeHistorical(snapshot, to: output, archive: false, folder: false)
    #expect(store.isBusy)
    let deadline = Date().addingTimeInterval(5)
    while store.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!store.isBusy && store.error == nil)
    #expect(try Data(contentsOf: output) == Data([0, 255, 128]))
}
