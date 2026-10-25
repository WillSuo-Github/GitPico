import AppKit
import UniformTypeIdentifiers
import Foundation
import Testing
@testable import GitCore
@testable import GitPico

@MainActor func dropStore() async throws -> RepositoryStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pico-drop-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try await GitProcess.run(["init", "-b", "main"], at: root)
    for (key, value) in [("user.name", "Test"), ("user.email", "test@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await GitProcess.run(["config", key, value], at: root) }
    try "original\n".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
    _ = try await GitProcess.run(["add", "."], at: root)
    _ = try await GitProcess.run(["commit", "-m", "Initial"], at: root)
    let store = RepositoryStore()
    store.repository = GitRepository(root: root); store.snapshot = try await store.repository?.snapshot()
    return store
}

@MainActor func dropToken(_ store: RepositoryStore, _ action: PicoDragAction) async throws -> PicoDragToken {
    let provider = store.dragProvider(action)
    let data: Data = try await withCheckedThrowingContinuation { continuation in
        provider.loadDataRepresentation(forTypeIdentifier: UTType.picoDrag.identifier) { data, error in
            if let data { continuation.resume(returning: data) }
            else { continuation.resume(throwing: error ?? GitFailure("No drag data")) }
        }
    }
    #expect(data.count < 200)
    return try JSONDecoder().decode(PicoDragToken.self, from: data)
}

@Test @MainActor func dragTokensRejectOtherRepositoriesUnsupportedTargetsAndBusyState() async throws {
    let store = try await dropStore(), repository = try #require(store.repository)
    let root = await repository.root
    defer { try? FileManager.default.removeItem(at: root) }
    try "local\n".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
    store.snapshot = try await repository.snapshot()
    let token = try await dropToken(store, .workingFiles(["readme.txt"]))
    #expect(store.canAcceptDrop(token, on: .stashes))
    #expect(!store.canAcceptDrop(token, on: .workingCopy))
    #expect(store.acceptDrop([token], on: .stashes, option: false))
    guard case .save(let paths, false) = store.stashRequest?.action else { Issue.record("Expected a reviewed file save"); return }
    #expect(paths == ["readme.txt"])
    store.isBusy = true
    #expect(!store.canAcceptDrop(token, on: .stashes))
    store.isBusy = false; store.repositoryToken = UUID()
    #expect(!store.canAcceptDrop(token, on: .stashes))
    #expect(!store.acceptDrop([token], on: .stashes, option: false))
}

@Test @MainActor func stashDropRoutesWholeFilesChunksAndLinesWithoutMutatingGit() async throws {
    let store = try await dropStore(), repository = try #require(store.repository)
    let root = await repository.root
    defer { try? FileManager.default.removeItem(at: root) }
    try "changed\n".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
    try await repository.saveStash(message: "Saved work")
    let stash = try #require(try await repository.stashList().first)
    let file = try #require(try await repository.stashDetail(stash).files.first)
    let diff = try await repository.stashFileDiff(stash, file: file)
    let document = PatchDocument(diff), hunk = try #require(document.hunks.first)
    let selection = document.selectableLines
    let actions: [PicoDragAction] = [.stash(stash), .stashFiles(stash, [file.path]), .stashChunk(stash, file, diff, hunk.id), .stashLines(stash, file, diff, selection)]
    for action in actions {
        let token = try await dropToken(store, action)
        #expect(store.canAcceptDrop(token, on: .workingCopy))
        #expect(store.acceptDrop([token], on: .workingCopy, option: false))
        switch store.stashRequest?.action {
        case .apply(let value): #expect(value.hash == stash.hash)
        case .files(let value, let paths): #expect(value.hash == stash.hash && paths == [file.path])
        case .chunk(let value, let path, let text, let id): #expect(value.hash == stash.hash && path.path == file.path && text == diff && id == hunk.id)
        case .lines(let value, let path, let text, let lines): #expect(value.hash == stash.hash && path.path == file.path && text == diff && lines == selection)
        default: Issue.record("Unexpected drop route")
        }
    }
    #expect(try await repository.snapshot().changes.isEmpty)
    #expect(try await repository.stashList().first?.hash == stash.hash)
}

@Test @MainActor func branchAndCommitDropsCreateReviewedOperations() async throws {
    let store = try await dropStore(), repository = try #require(store.repository)
    let root = await repository.root
    defer { try? FileManager.default.removeItem(at: root) }
    try await repository.createBranch("feature", at: "HEAD", checkout: false)
    let refs = try await repository.references()
    let head = try #require(refs.first { $0.isCurrent }), source = try #require(refs.first { $0.name == "feature" })
    let branch = try await dropToken(store, .reference(source))
    #expect(store.acceptDrop([branch], on: .reference(head), option: false))
    #expect(store.integrationRequest?.action == .merge)
    #expect(store.integrationRequest?.revision == source.hash)
    #expect(store.acceptDrop([branch], on: .reference(head), option: true))
    #expect(store.integrationRequest?.action == .rebase)
    #expect(!store.acceptDrop([branch], on: .reference(source), option: false))
    #expect(store.acceptDrop([branch], on: .branches, option: false))
    guard case .createBranch(let hash, nil) = store.managementRequest?.action else { Issue.record("Expected branch creation review"); return }
    #expect(hash == source.hash)
    let commit = try await dropToken(store, .commit(try await repository.commit(at: "HEAD")))
    #expect(store.acceptDrop([commit], on: .reference(head), option: false))
    #expect(store.integrationRequest?.action == .cherryPick)
    #expect(store.acceptDrop([commit], on: .reference(head), option: true))
    #expect(store.integrationRequest?.action == .revert)
}
