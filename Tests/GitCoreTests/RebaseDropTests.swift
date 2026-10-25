import Testing
@testable import GitCore

@Test func dragRebasePlansReorderAndFoldOnlyCurrentLinearCommits() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    var commits: [String] = []
    for i in 1...3 {
        try f.write("file\(i).txt", "content \(i)\n"); try await f.git(["add", "."]); try await f.repo.commit(message: "Commit \(i)")
        commits.append(try #require(try await f.repo.headPosition().hash))
    }
    let reordered = try await f.repo.rebaseDropPlan(source: commits[2], target: commits[0], position: .before)
    #expect(reordered.steps.map(\.hash) == [commits[2], commits[0], commits[1]])
    let folded = try await f.repo.rebaseDropPlan(source: commits[0], target: commits[2], position: .squash)
    #expect(folded.steps.map(\.hash) == [commits[1], commits[2], commits[0]])
    #expect(folded.steps.last?.action == .squash)
    #expect(folded.steps.last?.message == "Commit 3\n\nCommit 1")
    let fixup = try await f.repo.rebaseDropPlan(source: commits[0], target: commits[2], position: .fixup)
    #expect(fixup.steps.last?.action == .fixup)
    try await f.repo.startInteractiveRebase(reordered)
    #expect(try await f.git(["log", "--reverse", "--format=%s", "HEAD~3..HEAD"]).text == "Commit 3\nCommit 1\nCommit 2\n")
    await #expect(throws: GitFailure.self) { _ = try await f.repo.rebaseDropPlan(source: "HEAD", target: "HEAD", position: .before) }
}

@Test func rebasePlanRowDropMovesBeforeOrAfterInBothDirections() {
    let original = ["a", "b", "c", "d"].map { RebaseStep(hash: $0, originalMessage: $0, message: $0) }
    var steps = original
    #expect(RebaseStepEditing.move("a", relativeTo: "c", after: false, steps: &steps))
    #expect(steps.map(\.hash) == ["b", "a", "c", "d"])
    steps = original
    #expect(RebaseStepEditing.move("a", relativeTo: "c", after: true, steps: &steps))
    #expect(steps.map(\.hash) == ["b", "c", "a", "d"])
    steps = original
    #expect(RebaseStepEditing.move("d", relativeTo: "b", after: false, steps: &steps))
    #expect(steps.map(\.hash) == ["a", "d", "b", "c"])
    steps = original
    #expect(RebaseStepEditing.move("d", relativeTo: "b", after: true, steps: &steps))
    #expect(steps.map(\.hash) == ["a", "b", "d", "c"])
    let unchanged = steps.map(\.hash)
    #expect(!RebaseStepEditing.move("b", relativeTo: "b", after: false, steps: &steps))
    #expect(!RebaseStepEditing.move("missing", relativeTo: "a", after: true, steps: &steps))
    #expect(steps.map(\.hash) == unchanged)
}
