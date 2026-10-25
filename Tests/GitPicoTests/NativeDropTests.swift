import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import GitCore
@testable import GitPico

@MainActor private final class WindowlessDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = NSPoint(x: 20, y: 12)
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}

    func write(_ tokens: [PicoDragToken]) throws {
        draggingPasteboard.clearContents()
        let items = try tokens.map { token in
            let item = NSPasteboardItem()
            item.setData(try JSONEncoder().encode(token), forType: .init(UTType.picoDrag.identifier))
            return item
        }
        draggingPasteboard.writeObjects(items)
    }
    func releasePasteboard() { draggingPasteboard.releaseGlobally() }
}

@MainActor private func dropView(_ store: RepositoryStore, target: PicoDropTarget, option: Bool = false) -> NativePicoDropView {
    let view = NativePicoDropView(frame: NSRect(x: 0, y: 0, width: 250, height: 40))
    view.validate = { store.canAcceptDrop($0, on: target) }
    view.accept = { store.acceptDrop($0, on: target, point: $1, height: $2, option: option) }
    return view
}

@Test @MainActor func nativeWholeStashDropNegotiatesMoveAndDeliversExactlyOneReview() async throws {
    let store = try await dropStore(), repository = try #require(store.repository)
    let root = await repository.root
    defer { try? FileManager.default.removeItem(at: root) }
    try "stashed draft\n".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
    try await repository.saveStash(message: "Complete stash")
    let stash = try #require(try await repository.stashList().first)
    let token = try await dropToken(store, .stash(stash))
    let sender = WindowlessDragInfo(); defer { sender.releasePasteboard() }
    try sender.write([token]); sender.draggingSourceOperationMask = .move
    let view = dropView(store, target: .workingCopy)
    #expect(view.window == nil)
    #expect(view.hitTest(NSPoint(x: 20, y: 10)) == nil)
    #expect(view.draggingEntered(sender) == .move)
    #expect(view.isDropTargeted)
    #expect(sender.numberOfValidItemsForDrop == 1)
    #expect(view.prepareForDragOperation(sender))
    #expect(view.performDragOperation(sender))
    #expect(!view.isDropTargeted)
    guard case .apply(let applied) = store.stashRequest?.action else { Issue.record("Whole-stash review was not delivered"); return }
    #expect(applied.hash == stash.hash)
    let reviewID = store.stashRequest?.id
    #expect(!view.performDragOperation(sender))
    #expect(store.stashRequest?.id == reviewID)
    #expect(view.hitTest(NSPoint(x: 20, y: 10)) == nil)
    #expect(try await repository.snapshot().changes.isEmpty)
}

@Test @MainActor func nativeDropRevalidatesBusyStatePayloadAndSourceOperation() async throws {
    let store = try await dropStore(), repository = try #require(store.repository)
    let root = await repository.root
    defer { try? FileManager.default.removeItem(at: root) }
    let commit = try await repository.commit(at: "HEAD")
    let token = try await dropToken(store, .commit(commit))
    let view = dropView(store, target: .branches), sender = WindowlessDragInfo()
    defer { sender.releasePasteboard() }
    try sender.write([token]); sender.draggingSourceOperationMask = [.copy, .move]
    #expect(view.draggingEntered(sender) == .copy)
    store.isBusy = true
    #expect(view.draggingUpdated(sender).isEmpty)
    #expect(!view.isDropTargeted)
    #expect(!view.prepareForDragOperation(sender))
    #expect(!view.performDragOperation(sender))
    #expect(store.managementRequest == nil)
    store.isBusy = false
    #expect(view.draggingEntered(sender) == .copy)
    let replacement = try await dropToken(store, .commit(commit))
    try sender.write([replacement])
    #expect(!view.prepareForDragOperation(sender))
    #expect(!view.performDragOperation(sender))
    #expect(!view.isDropTargeted)
    sender.draggingSourceOperationMask = .link
    #expect(view.draggingEntered(sender).isEmpty)
    #expect(!view.performDragOperation(sender))
    #expect(store.managementRequest == nil)
}

@Test @MainActor func nativeDropCombinesAllSelectedWorkingFilesAndRejectsMixedPayloads() async throws {
    let store = try await dropStore(), repository = try #require(store.repository)
    let root = await repository.root
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["readme.txt", "new[1].txt"] { try "draft\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    store.snapshot = try await repository.snapshot()
    let first = try await dropToken(store, .workingFiles(["readme.txt"]))
    let second = try await dropToken(store, .workingFiles(["new[1].txt", "readme.txt"]))
    let view = dropView(store, target: .stashes), sender = WindowlessDragInfo()
    defer { sender.releasePasteboard() }
    try sender.write([first, second])
    #expect(view.draggingEntered(sender) == .copy)
    #expect(sender.numberOfValidItemsForDrop == 2)
    #expect(view.performDragOperation(sender))
    guard case .save(let paths, false) = store.stashRequest?.action else { Issue.record("Missing selected-file review"); return }
    #expect(paths == ["new[1].txt", "readme.txt"])
    let unrelated = try await dropToken(store, .commit(try await repository.commit(at: "HEAD")))
    try sender.write([first, unrelated])
    #expect(view.draggingEntered(sender).isEmpty)
    #expect(!view.performDragOperation(sender))
    #expect(try await repository.stashList().isEmpty)
    #expect(try await repository.snapshot().changes.count == 2)
}

@Test @MainActor func nativeDropRejectsInvalidDataAndClearsTargetOnExitOrCancel() async throws {
    let store = try await dropStore(), repository = try #require(store.repository)
    let root = await repository.root
    defer { try? FileManager.default.removeItem(at: root) }
    let token = try await dropToken(store, .commit(try await repository.commit(at: "HEAD")))
    let view = dropView(store, target: .branches), sender = WindowlessDragInfo()
    defer { sender.releasePasteboard() }
    try sender.write([token])
    #expect(view.draggingEntered(sender) == .copy)
    view.draggingExited(sender)
    #expect(!view.isDropTargeted)
    #expect(!view.performDragOperation(sender))
    #expect(view.draggingEntered(sender) == .copy)
    view.draggingEnded(sender)
    #expect(!view.isDropTargeted)
    #expect(view.hitTest(NSPoint(x: 20, y: 10)) == nil)
    sender.draggingPasteboard.clearContents()
    sender.draggingPasteboard.setData(Data(repeating: 0, count: 513), forType: .init(UTType.picoDrag.identifier))
    #expect(view.draggingEntered(sender).isEmpty)
    #expect(!view.performDragOperation(sender))
    try sender.write([PicoDragToken(id: token.id, repository: UUID())])
    #expect(view.draggingEntered(sender).isEmpty)
    #expect(store.managementRequest == nil)
}

@MainActor private func waitForDropTask(_ store: RepositoryStore) async throws {
    await store.operationTask?.value
    #expect(!store.isBusy)
}

@Test @MainActor func nativeHeadDropPinsDestinationAndRejectsExternalBranchSwitch() async throws {
    let store = try await dropStore(), repository = try #require(store.repository)
    let root = await repository.root
    defer { try? FileManager.default.removeItem(at: root) }
    try await repository.createBranch("other", at: "HEAD", checkout: false)
    let head = try #require(try await repository.references().first { $0.isCurrent })
    let commit = try await repository.commit(at: "HEAD")
    let token = try await dropToken(store, .commit(commit))
    let view = dropView(store, target: .reference(head)), sender = WindowlessDragInfo()
    defer { sender.releasePasteboard() }
    try sender.write([token])
    #expect(view.draggingEntered(sender) == .copy)
    #expect(view.performDragOperation(sender))
    let request = try #require(store.integrationRequest)
    #expect(request.expectedHead == HeadPosition(branch: "refs/heads/main", hash: commit.hash))
    try await repository.switchBranch("other")
    store.integrate(request, revision: commit.hash, expectedHead: try await repository.headPosition())
    try await waitForDropTask(store)
    #expect(store.error?.contains("HEAD changed") == true)
    #expect(try await repository.headPosition().branch == "refs/heads/other")
    #expect(try await repository.headPosition().hash == commit.hash)
    #expect(try await repository.currentOperation() == .none)
    #expect(try await repository.snapshot().changes.isEmpty)
}

@Test(arguments: [0, 1, 2, 3]) @MainActor func nativeCommitDropUsesEdgesForReorderAndCenterForFold(_ variant: Int) async throws {
    let store = try await dropStore(), repository = try #require(store.repository)
    let root = await repository.root
    defer { try? FileManager.default.removeItem(at: root) }
    var hashes: [String] = []
    for i in 1...3 {
        try "content\n".write(to: root.appendingPathComponent("file\(i).txt"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(["add", "."], at: root)
        _ = try await GitProcess.run(["commit", "-m", "Commit \(i)"], at: root)
        hashes.append(try #require(try await repository.headPosition().hash))
    }
    store.snapshot = try await repository.snapshot()
    let source = try await repository.commit(at: hashes[2]), target = try await repository.commit(at: hashes[0])
    let token = try await dropToken(store, .commit(source))
    let view = dropView(store, target: .commit(target, .squash), option: variant == 3), sender = WindowlessDragInfo()
    defer { sender.releasePasteboard() }
    try sender.write([token])
    let y: CGFloat = variant == 0 ? 2 : variant == 1 ? 38 : 20
    sender.draggingLocation = view.convert(NSPoint(x: 20, y: y), to: nil)
    #expect(view.draggingEntered(sender) == .copy)
    #expect(view.performDragOperation(sender))
    try await waitForDropTask(store)
    #expect(store.error == nil)
    let plan = try #require(store.rebaseRequest?.preparedPlan)
    switch variant {
    case 0: #expect(plan.steps.map(\.hash) == [hashes[0], hashes[2], hashes[1]])
    case 1: #expect(plan.steps.map(\.hash) == [hashes[2], hashes[0], hashes[1]])
    default:
        #expect(plan.steps.map(\.hash) == [hashes[0], hashes[2], hashes[1]])
        #expect(plan.steps[1].action == (variant == 3 ? .fixup : .squash))
    }
    #expect(try await repository.headPosition().hash == hashes[2])
    #expect(try await repository.currentOperation() == .none)
}

@Test @MainActor func rebasePlanReloadRejectsTokensFromEarlierPlan() async throws {
    let store = try await dropStore(), repository = try #require(store.repository)
    let root = await repository.root
    defer { try? FileManager.default.removeItem(at: root) }
    let originalPlan = UUID(), replacementPlan = UUID()
    let token = try await dropToken(store, .rebaseStep("original-commit", originalPlan))
    #expect(store.rebaseDragSource([token], planID: originalPlan) == "original-commit")
    #expect(store.rebaseDragSource([token], planID: replacementPlan) == nil)
    #expect(store.rebaseDragSource([token, token], planID: originalPlan) == nil)
    store.repositoryToken = UUID()
    #expect(store.rebaseDragSource([token], planID: originalPlan) == nil)
}

@Test @MainActor func nativeCommitDropRejectsBranchChangesBeforePlanPreparation() async throws {
    let store = try await dropStore(), repository = try #require(store.repository)
    let root = await repository.root
    defer { try? FileManager.default.removeItem(at: root) }
    var commits: [Commit] = []
    for i in 1...2 {
        try "independent\n".write(to: root.appendingPathComponent("file\(i).txt"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(["add", "."], at: root)
        _ = try await GitProcess.run(["commit", "-m", "Commit \(i)"], at: root)
        commits.append(try await repository.commit(at: "HEAD"))
    }
    store.snapshot = try await repository.snapshot()
    let token = try await dropToken(store, .commit(commits[1]))
    let view = dropView(store, target: .commit(commits[0], .squash)), sender = WindowlessDragInfo()
    defer { sender.releasePasteboard() }
    try sender.write([token])
    #expect(view.draggingEntered(sender) == .copy)
    // Same commit hash, different branch: hash-only validation would miss this change.
    try await repository.createBranch("other", at: "HEAD", checkout: true)
    #expect(view.performDragOperation(sender))
    try await waitForDropTask(store)
    #expect(store.rebaseRequest == nil)
    #expect(store.error?.contains("HEAD changed outside this drag") == true)
    #expect(try await repository.headPosition().branch == "refs/heads/other")
    #expect(try await repository.headPosition().hash == commits[1].hash)
    #expect(try await repository.snapshot().changes.isEmpty)
}
