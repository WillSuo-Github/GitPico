import Foundation
import GitCore
import Testing
@testable import GitPico

@MainActor struct WorkingAppFixture {
    let root: URL
    let repository: GitRepository
    let store: RepositoryStore
    static func make(reader: any WorkingDiffReading = GitWorkingDiffReader()) async throws -> Self {
        let f = try await PreviewFixture.make(commits: 1, branches: 1)
        let url = await f.repository.root
        for name in ["a.txt", "b.txt", "c.txt"] { try Data("original\n".utf8).write(to: url.appendingPathComponent(name)) }
        _ = try await GitProcess.run(["add", "."], at: url)
        _ = try await GitProcess.run(["commit", "-m", "Files"], at: url)
        let store = RepositoryStore(library: RepositoryLibrary(file: f.root.appendingPathComponent("working-library.json"), legacy: []), workingDiffReader: reader)
        store.toolPreferences = ExternalToolPreferences(file: f.root.appendingPathComponent("tools.json"))
        store.repository = f.repository; store.snapshot = try await f.repository.snapshot()
        await store.rebuildWorkingList()
        return Self(root: f.root, repository: f.repository, store: store)
    }
    func write(_ name: String, _ text: String) async throws { try Data(text.utf8).write(to: await repository.root.appendingPathComponent(name)) }
    func sync() async throws { store.snapshot = try await repository.snapshot(); await store.rebuildWorkingList() }
    func finish() async { await store.operationTask?.value; await store.detailTask?.value }
    func clean() { store.cancelPreviewWork(); try? FileManager.default.removeItem(at: root) }
}

@Test @MainActor func workingMultiselectionStagesOnlyTargetsAndKeepsActiveFile() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    for name in ["a.txt", "b.txt", "c.txt"] { try await f.write(name, "edited " + name + "\n") }
    try await f.sync()
    f.store.setWorkingSelection(["b.txt"])
    f.store.setWorkingSelection(["a.txt", "b.txt"])
    #expect(f.store.selectedChange == "a.txt")
    f.store.setWorkingSelection(["a.txt", "b.txt", "c.txt"])
    #expect(f.store.selectedChange == "c.txt")
    f.store.setWorkingSelection(["a.txt", "c.txt"])
    #expect(f.store.selectedChange == "c.txt")
    f.store.stageSelectedFiles("a.txt"); await f.finish()
    #expect(Set(f.store.staged.map(\.path)) == ["a.txt", "c.txt"])
    #expect(f.store.selectedChange == "c.txt" && f.store.stagedDiff)
    f.store.unstageSelectedFiles("a.txt"); await f.finish()
    #expect(f.store.staged.isEmpty && f.store.selectedChange == "c.txt" && !f.store.stagedDiff)
    f.store.setWorkingSelection([])
    #expect(f.store.selectedChange == nil && f.store.diff.isEmpty && !f.store.isLoadingDiff)
}

@Test @MainActor func partialCheckboxStagesRemainingChangesAndCommitKeepsUnstagedContent() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    try await f.write("a.txt", "staged\n")
    try await f.sync(); f.store.stage([try #require(f.store.changes.first)]); await f.finish()
    try await f.write("a.txt", "remaining\n")
    try await f.sync()
    f.store.setWorkingSelection(["a.txt"]); await f.store.detailTask?.value
    let partial = try #require(f.store.currentChange)
    #expect(partial.isStaged && partial.isUnstaged && !f.store.stagedDiff)
    f.store.toggleWorkingFile(partial); await f.finish()
    #expect(f.store.currentChange?.isStaged == true && f.store.currentChange?.isUnstaged == false)
    try await f.write("a.txt", "keep after commit\n")
    try await f.sync(); f.store.selectChange(try #require(f.store.currentChange), staged: false)
    f.store.commitSubject = "Commit staged text"; f.store.commitBody = "With a body"
    #expect(f.store.canCommit)
    f.store.commit(); await f.finish()
    #expect(f.store.error == nil && f.store.commitFeedback == "Commit created.")
    #expect(f.store.commitSubject.isEmpty && f.store.commitBody.isEmpty)
    #expect(f.store.selectedChange == "a.txt" && f.store.selectedWorkingFiles == ["a.txt"])
    #expect(f.store.currentChange?.isUnstaged == true && !f.store.stagedDiff)
    #expect(f.store.diff.contains("keep after commit"))
    #expect(try await GitProcess.run(["show", "HEAD:a.txt"], at: f.repository.root).text == "remaining\n")
    #expect(try await GitProcess.run(["show", ":a.txt"], at: f.repository.root).text == "remaining\n")
    #expect(try String(contentsOf: await f.repository.root.appendingPathComponent("a.txt"), encoding: .utf8) == "keep after commit\n")
}

@Test @MainActor func rejectedCommitKeepsDraftStagingAndHead() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    try await f.write("a.txt", "edited\n"); try await f.sync()
    f.store.stage(f.store.changes); await f.finish()
    let url = await f.repository.root, head = try await f.repository.headPosition()
    let hooks = f.root.appendingPathComponent("hooks")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    let hook = hooks.appendingPathComponent("pre-commit")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    _ = try await GitProcess.run(["config", "core.hooksPath", hooks.path], at: url)
    f.store.commitSubject = "Keep this draft"; f.store.commitBody = "Keep this description"
    f.store.commit(); await f.finish()
    #expect(f.store.error != nil && f.store.commitFeedback == nil)
    #expect(f.store.commitSubject == "Keep this draft" && f.store.commitBody == "Keep this description")
    #expect(f.store.staged.map(\.path) == ["a.txt"])
    #expect(try await f.repository.headPosition() == head)
}

@Test @MainActor func fileFilterPrunesSelectionAndDoesNotStageIgnoredFiles() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    try await f.write("a.txt", "edited\n"); try await f.write(".gitignore", "*.log\n"); try await f.write("private.log", "private\n")
    try await f.sync(); f.store.setWorkingSelection(["a.txt"])
    f.store.search = "no matches"; await f.store.rebuildWorkingList()
    #expect(f.store.workingList.files.isEmpty && f.store.selectedWorkingFiles.isEmpty && f.store.diff.isEmpty)
    f.store.search = "private"; f.store.showIgnoredFiles = true; await f.store.refreshFileBrowser()
    f.store.setWorkingSelection(["private.log"])
    f.store.stageSelectedFiles(); await f.finish()
    #expect(f.store.staged.isEmpty && f.store.workingTargets().isEmpty)
    #expect(f.store.selectedChange == "private.log")
}

actor RecordingWorkingReader: WorkingDiffReading {
    var reads = 0
    var failures = 0
    func failOnce() { failures = 1 }
    var blocked = false
    var waiting = false
    var continuation: CheckedContinuation<Void,Never>?
    func block() { blocked = true; waiting = false }
    func release() { blocked = false; continuation?.resume(); continuation = nil }
    func diff(_ change: FileChange, staged: Bool, context: Int, ignoreWhitespace: Bool, in repository: GitRepository) async throws -> String {
        reads += 1
        if failures > 0 { failures -= 1; throw GitFailure("Temporary diff read failure") }
        let value = try await repository.diff(change, staged: staged, context: context, ignoreWhitespace: ignoreWhitespace)
        if blocked && change.path == "a.txt" { waiting = true; await withCheckedContinuation { continuation = $0 } }
        return value
    }
}
@Test @MainActor func workingDiffDeduplicatesSelectionAndRejectsLateFileResults() async throws {
    let reader = RecordingWorkingReader()
    let f = try await WorkingAppFixture.make(reader: reader); defer { f.clean() }
    try await f.write("a.txt", "AAA\n"); try await f.write("b.txt", "BBB\n"); try await f.sync()
    await reader.block(); f.store.setWorkingSelection(["a.txt"])
    let previous = f.store.detailTask
    let deadline = Date().addingTimeInterval(5)
    while !(await reader.waiting) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await reader.waiting)
    f.store.selectChange(try #require(f.store.currentChange), staged: false)
    #expect(await reader.reads == 1)
    f.store.setWorkingSelection(["b.txt"]); await f.store.detailTask?.value
    await reader.release(); await previous?.value
    #expect(f.store.diff.contains("BBB") && !f.store.diff.contains("AAA"))
    #expect(f.store.workingPreparedDiff?.source == f.store.diff)
    f.store.selectChange(try #require(f.store.currentChange), staged: false); await f.store.detailTask?.value
    #expect(await reader.reads == 2)
    f.store.diffContext = 3; f.store.selectChange(try #require(f.store.currentChange), staged: false); await f.store.detailTask?.value
    #expect(await reader.reads == 3)
}

@Test @MainActor func stagingAndUnstagingKeepPreparedPreviewUntilReplacementIsReady() async throws {
    let reader = RecordingWorkingReader()
    let f = try await WorkingAppFixture.make(reader: reader); defer { f.clean() }
    try await f.write("a.txt", "edited\n"); try await f.sync()
    f.store.setWorkingSelection(["a.txt"]); await f.store.detailTask?.value
    let original = f.store.diff
    #expect(!original.isEmpty && f.store.workingPreparedDiff?.source == original)
    for staged in [true, false] {
        await reader.block()
        f.store.toggleWorkingFile(try #require(f.store.currentChange))
        await f.store.operationTask?.value
        let deadline = Date().addingTimeInterval(5)
        while !(await reader.waiting) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let waiting = await reader.waiting
        #expect(waiting)
        #expect(f.store.stagedDiff == staged && f.store.isLoadingDiff)
        #expect(f.store.diff == original && f.store.workingPreparedDiff?.source == original)
        // A delayed read must not allow an action against the retained patch.
        let operation = f.store.operationTask
        f.store.stageChunk(0)
        #expect(!f.store.isBusy)
        await operation?.value
        await reader.release(); await f.store.detailTask?.value
        #expect(!f.store.isLoadingDiff && f.store.diffError == nil)
        #expect(f.store.workingPreparedDiff?.source == f.store.diff && f.store.diff.contains("+edited"))
        #expect(try await GitProcess.run(["show", ":a.txt"], at: f.repository.root).text == (staged ? "edited\n" : "original\n"))
    }
    #expect(await reader.reads == 3)
}

@Test @MainActor func partialStagingPublishesPreparedRemainingDiffWithoutBlankingPreview() async throws {
    let reader = RecordingWorkingReader()
    let f = try await WorkingAppFixture.make(reader: reader); defer { f.clean() }
    try await f.write("a.txt", "first\nsecond\n"); try await f.sync()
    f.store.setWorkingSelection(["a.txt"]); await f.store.detailTask?.value
    let original = f.store.diff, prepared = try #require(f.store.workingPreparedDiff)
    let ids = Set(prepared.previews.flatMap { preview in preview.lines.compactMap { line -> PatchLineID? in
        line.kind == .deletion || line.text == "+first" ? PatchLineID(hunk: preview.id, line: line.id) : nil
    } })
    await reader.block(); f.store.stageLines(ids); await f.store.operationTask?.value
    #expect(f.store.isLoadingDiff && f.store.diff == original && f.store.workingPreparedDiff?.source == original)
    await reader.release(); await f.store.detailTask?.value
    #expect(f.store.error == nil && !f.store.isLoadingDiff && !f.store.stagedDiff)
    #expect(f.store.diff != original && f.store.diff.contains("+second"))
    #expect(f.store.workingPreparedDiff?.source == f.store.diff)
    #expect(try await GitProcess.run(["show", ":a.txt"], at: f.repository.root).text == "first\n")
}

@Test @MainActor func automaticDiffRefreshKeepsPreviewAndDetectsEditsWithUnchangedStatus() async throws {
    let reader = RecordingWorkingReader()
    let f = try await WorkingAppFixture.make(reader: reader); defer { f.clean() }
    try await f.write("a.txt", "first edit\n"); try await f.sync()
    f.store.setWorkingSelection(["a.txt"]); await f.store.detailTask?.value
    let original = f.store.diff, status = f.store.changes
    try await f.write("a.txt", "second edit\n")
    await reader.block(); await f.store.refreshAutomatically()
    #expect(f.store.changes == status)
    #expect(f.store.isLoadingDiff && f.store.diff == original && f.store.workingPreparedDiff?.source == original)
    await reader.release(); await f.store.detailTask?.value
    #expect(!f.store.isLoadingDiff && f.store.diff.contains("+second edit"))
    #expect(f.store.workingPreparedDiff?.source == f.store.diff)
    f.store.setWorkingSelection([])
    #expect(f.store.diff.isEmpty && f.store.workingPreparedDiff == nil)
}

@Test func preparedPatchSelectionUsesOnlyVisibleChangedLines() {
    let source = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,3 +1,3 @@\n-one\n+ONE\n unchanged\n-two\n+TWO\n"
    let value = PreparedPatch.make(source)
    #expect(value.selectableOrder.count == 4)
    var selection = PatchLineSelection()
    selection.toggle(value.selectableOrder[0], extending: false, order: value.selectableOrder)
    selection.toggle(value.selectableOrder[3], extending: true, order: value.selectableOrder)
    #expect(selection.ids.count == 4)
    selection.clear(); #expect(selection.ids.isEmpty && selection.anchor == nil)
    let large = PreparedPatch.make("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1,9000 @@\n" + String(repeating: "+line\n", count: 9000))
    #expect(large.previews.first?.isTruncated == true && large.selectableOrder.isEmpty)
}

@Test @MainActor func failedWorkingDiffCanRetryWithoutLosingFileSelection() async throws {
    let reader = RecordingWorkingReader()
    let f = try await WorkingAppFixture.make(reader: reader); defer { f.clean() }
    try await f.write("a.txt", "edited\n"); try await f.sync()
    await reader.failOnce(); f.store.setWorkingSelection(["a.txt"]); await f.store.detailTask?.value
    #expect(f.store.diffError == "Temporary diff read failure" && f.store.error == nil)
    #expect(f.store.selectedChange == "a.txt")
    f.store.selectChange(try #require(f.store.currentChange), staged: false); await f.store.detailTask?.value
    #expect(f.store.diffError == nil && f.store.diff.contains("edited"))
    #expect(await reader.reads == 2)
}

@Test @MainActor func workingSelectedLinesStageAndUnstageAcrossDiffSides() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    try await f.write("a.txt", "first\nsecond\n"); try await f.sync()
    f.store.setWorkingSelection(["a.txt"]); await f.store.detailTask?.value
    let prepared = PreparedPatch.make(f.store.diff)
    let ids = Set(prepared.previews.flatMap { preview in preview.lines.compactMap { line -> PatchLineID? in
        line.kind == .deletion || line.text == "+first" ? PatchLineID(hunk: preview.id, line: line.id) : nil
    } })
    f.store.stageLines(ids); await f.finish()
    #expect(f.store.error == nil && f.store.currentChange?.isStaged == true && f.store.currentChange?.isUnstaged == true)
    #expect(try await GitProcess.run(["show", ":a.txt"], at: f.repository.root).text == "first\n")
    f.store.selectChange(try #require(f.store.currentChange), staged: true); await f.store.detailTask?.value
    let staged = PreparedPatch.make(f.store.diff)
    f.store.stageLines(Set(staged.selectableOrder)); await f.finish()
    #expect(f.store.error == nil && f.store.currentChange?.isStaged == false && !f.store.stagedDiff)
    #expect(try await GitProcess.run(["show", ":a.txt"], at: f.repository.root).text == "original\n")
    #expect(try String(contentsOf: await f.repository.root.appendingPathComponent("a.txt"), encoding: .utf8) == "first\nsecond\n")
}

@Test @MainActor func successfulCommitWithUndoFailureClearsDraftAndReportsWarning() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    try await f.write("a.txt", "committed\n"); try await f.sync()
    f.store.stage(f.store.changes); await f.finish()
    let journal = await f.repository.root.appendingPathComponent(".git/gitpico/undo.json")
    try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
    f.store.commitSubject = "Created once"; f.store.commitBody = "Complete draft"
    f.store.commit(); await f.finish()
    #expect(f.store.error == nil && f.store.commitFeedback == "Commit created.")
    #expect(f.store.commitWarning?.contains("Undo record") == true)
    #expect(f.store.operationFeedback?.phase == .succeeded && f.store.operationFeedback?.warning != nil)
    #expect(f.store.operationFeedback?.isVisible == true && f.store.operationFeedback?.title.contains("Action required") == true)
    #expect(f.store.commitSubject.isEmpty && f.store.commitBody.isEmpty && !f.store.canCommit)
    #expect(f.store.undoAvailability == nil && f.store.staged.isEmpty)
    #expect(try await GitProcess.run(["log", "-1", "--format=%s"], at: f.repository.root).text == "Created once\n")
}
