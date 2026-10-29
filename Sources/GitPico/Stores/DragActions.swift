import AppKit
import OSLog
import GitCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let picoDrag = UTType(exportedAs: "com.willsuo.gitpico.drag", conformingTo: .data) }

struct PicoDragToken: Codable, Equatable, Sendable {
    let id: UUID
    let repository: UUID
}

enum PicoDragAction {
    case workingFiles([String]), stash(Stash), stashFiles(Stash, [String]), stashChunk(Stash, StashFile, String, Int)
    case stashLines(Stash, StashFile, String, Set<PatchLineID>), reference(Reference), commit(Commit), rebaseStep(String, UUID)
}

enum PicoDropTarget { case workingCopy, stashes, branches, tags, remote(String), reference(Reference), commit(Commit, RebaseDropPosition) }

extension RepositoryStore {
    func dragProvider(_ action: PicoDragAction) -> NSItemProvider {
        let token = makeDragToken(action)
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(token)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.picoDrag.identifier, visibility: .ownProcess) { completion in
            completion(data, nil); return nil
        }
        return provider
    }

    func makeDragToken(_ action: PicoDragAction) -> PicoDragToken {
        Logger(subsystem: "com.willsuo.GitPico", category: "DragDrop").debug("Drag source created")
        let token = PicoDragToken(id: UUID(), repository: repositoryToken)
        if dragActions.count > 512 { dragActions.removeAll() }
        dragActions[token.id] = action
        return token
    }

    func dragAction(_ token: PicoDragToken) -> PicoDragAction? {
        guard token.repository == repositoryToken, !isBusy else { return nil }
        return dragActions[token.id]
    }

    func rebaseDragSource(_ tokens: [PicoDragToken], planID: UUID) -> String? {
        guard tokens.count == 1, case .rebaseStep(let hash, let sourcePlan) = dragAction(tokens[0]), sourcePlan == planID else { return nil }
        return hash
    }

    private func combinedDragAction(_ tokens: [PicoDragToken]) -> PicoDragAction? {
        guard !tokens.isEmpty else { return nil }
        if tokens.count == 1 { return dragAction(tokens[0]) }
        var paths: Set<String> = []
        for token in tokens {
            guard case .workingFiles(let files) = dragAction(token) else { return nil }
            paths.formUnion(files)
        }
        return paths.isEmpty ? nil : .workingFiles(paths.sorted())
    }

    private func currentDropHead() -> HeadPosition? {
        guard let current = snapshot?.references.first(where: { $0.isCurrent && $0.isLocal }) else { return nil }
        return HeadPosition(branch: current.fullName, hash: current.hash)
    }

    private func isCurrentDropTarget(_ ref: Reference) -> Bool {
        currentDropHead() == HeadPosition(branch: ref.fullName, hash: ref.hash)
    }

    func canAcceptDrop(_ token: PicoDragToken, on target: PicoDropTarget) -> Bool { canAcceptDrop([token], on: target) }

    func canAcceptDrop(_ tokens: [PicoDragToken], on target: PicoDropTarget) -> Bool {
        guard let action = combinedDragAction(tokens) else { return false }
        switch (target, action) {
        case (.stashes, .workingFiles(let paths)): return !paths.isEmpty && paths.allSatisfy { path in changes.contains { $0.path == path && !$0.isConflicted } }
        case (.workingCopy, .stash), (.workingCopy, .stashFiles), (.workingCopy, .stashChunk), (.workingCopy, .stashLines): return true
        case (.branches, .reference), (.branches, .commit), (.tags, .reference), (.tags, .commit): return true
        case (.remote, .reference(let ref)): return ref.isLocal || ref.isTag
        case (.reference(let target), .reference(let source)): return canIntegrate && target.isCurrent && isCurrentDropTarget(target) && target.fullName != source.fullName
        case (.reference(let target), .commit): return canIntegrate && target.isCurrent && isCurrentDropTarget(target)
        case (.commit(let target, _), .commit(let source)): return currentDropHead() != nil && source.hash != target.hash
        default: return false
        }
    }

    @discardableResult func acceptDrop(_ tokens: [PicoDragToken], on target: PicoDropTarget, point: CGPoint, height: CGFloat, option: Bool? = nil) -> Bool {
        if case .commit(let commit, _) = target {
            return acceptDrop(tokens, on: .commit(commit, .historyRow(y: point.y, height: height)), option: option)
        }
        return acceptDrop(tokens, on: target, option: option)
    }

    @discardableResult func acceptDrop(_ tokens: [PicoDragToken], on target: PicoDropTarget, option: Bool? = nil) -> Bool {
        Logger(subsystem: "com.willsuo.GitPico", category: "DragDrop").info("Drop routed")
        guard canAcceptDrop(tokens, on: target), let action = combinedDragAction(tokens) else { return false }
        let option = option ?? NSEvent.modifierFlags.contains(.option)
        switch (target, action) {
        case (.stashes, .workingFiles(let paths)):
            guard !paths.isEmpty, paths.allSatisfy({ path in changes.contains { $0.path == path && !$0.isConflicted } }) else { return false }
            stashAction(.save(paths, false))
        case (.workingCopy, .stash(let stash)): stashAction(.apply(stash))
        case (.workingCopy, .stashFiles(let stash, let paths)): stashAction(.files(stash, paths))
        case (.workingCopy, .stashChunk(let stash, let file, let diff, let hunk)): stashAction(.chunk(stash, file, diff, hunk))
        case (.workingCopy, .stashLines(let stash, let file, let diff, let lines)): stashAction(.lines(stash, file, diff, lines))
        case (.branches, .reference(let ref)): manage(.createBranch(ref.hash, ref.isRemote ? ref.fullName : nil))
        case (.branches, .commit(let commit)): manage(.createBranch(commit.hash, nil))
        case (.tags, .reference(let ref)): manage(.createTag(ref.hash))
        case (.tags, .commit(let commit)): manage(.createTag(commit.hash))
        case (.remote(let remote), .reference(let ref)) where ref.isLocal || ref.isTag: manage(.publish(ref, remote, nil, false))
        case (.reference(let target), .reference(let source)) where target.isCurrent && target.fullName != source.fullName:
            if source.isRemote && option { manage(.createBranch(source.hash, source.fullName)) }
            else { integrationRequest = IntegrationRequest(action: option ? .rebase : .merge, revision: source.hash, expectedHead: HeadPosition(branch: target.fullName, hash: target.hash), sourceReference: source) }
        case (.reference(let target), .commit(let commit)) where target.isCurrent:
            integrationRequest = IntegrationRequest(action: option ? .revert : .cherryPick, revision: commit.hash, expectedHead: HeadPosition(branch: target.fullName, hash: target.hash))
        case (.commit(let target, let position), .commit(let source)):
            guard let repository, let expectedHead = currentDropHead(), source.hash != target.hash else { return false }
            isBusy = true; activity = String(localized: "Preparing rebase plan…")
            operationTask = Task {
                defer { isBusy = false; activity = "" }
                do {
                    let plan = try await repository.rebaseDropPlan(source: source.hash, target: target.hash, position: option && position == .squash ? .fixup : position)
                    guard plan.position == expectedHead else { throw appFailure("HEAD changed outside this drag. Refresh and drag again.") }
                    rebaseRequest = RebaseRequest(base: plan.base, preparedPlan: plan)
                }
                catch { self.error = error.localizedDescription }
            }
        default: return false
        }
        return true
    }
}
