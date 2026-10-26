import Foundation

public enum RebaseDropPosition: Sendable { case before, after, squash, fixup }

extension GitRepository {
    public func rebaseDropPlan(source: String, target: String, position: RebaseDropPosition) async throws -> InteractiveRebasePlan {
        let source = try await commit(at: source), target = try await commit(at: target)
        guard source.hash != target.hash, let sourceParent = source.parents.first, let targetParent = target.parents.first else { throw GitFailure("Choose two different non-root commits on the current linear branch.") }
        let sourceOlder = try await GitProcess.run(["merge-base", "--is-ancestor", source.hash, target.hash], at: root, allowed: [0, 1]).status == 0
        var plan = try await rebasePlan(after: sourceOlder ? sourceParent : targetParent)
        guard !plan.preserveMerges else { throw GitFailure("Use the merge-preserving Interactive Rebase sheet for this range; drag reordering requires a linear range.") }
        guard let from = plan.steps.firstIndex(where: { $0.hash == source.hash }), plan.steps.contains(where: { $0.hash == target.hash }) else { throw GitFailure("Drag commits within the current linear branch to reorder or combine them. Use the HEAD branch to cherry-pick other commits.") }
        var moved = plan.steps.remove(at: from)
        guard let to = plan.steps.firstIndex(where: { $0.hash == target.hash }) else { throw GitFailure("The target commit is no longer in the plan.") }
        switch position {
        case .before: plan.steps.insert(moved, at: to)
        case .after: plan.steps.insert(moved, at: to + 1)
        case .squash, .fixup:
            moved.action = position == .fixup ? .fixup : .squash
            if position == .squash { moved.message = plan.steps[to].message + "\n\n" + moved.message }
            plan.steps.insert(moved, at: to + 1)
        }
        return plan
    }
}

extension RebaseDropPosition {
    /// History rows are newest first; their top edge means later in replay order.
    public static func historyRow(y: Double, height: Double) -> RebaseDropPosition {
        if y < 6 { return .after }
        if y > height - 6 { return .before }
        return .squash
    }
}

public enum RebaseStepEditing {
    @discardableResult public static func move(_ source: String, relativeTo target: String, after: Bool, steps: inout [RebaseStep]) -> Bool {
        guard source != target, let from = steps.firstIndex(where: { $0.id == source }), steps.contains(where: { $0.id == target }) else { return false }
        let value = steps.remove(at: from)
        let targetIndex = steps.firstIndex(where: { $0.id == target })!
        steps.insert(value, at: targetIndex + (after ? 1 : 0))
        return true
    }
}
