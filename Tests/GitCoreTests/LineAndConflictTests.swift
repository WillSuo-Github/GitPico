import Foundation
import Testing
@testable import GitCore

private func select(_ diff: String, where predicate: (DiffLine) -> Bool) -> Set<PatchLineID> {
    Set(PatchDocument(diff).hunks.flatMap { hunk in
        DiffDocument(hunk.text).lines.filter(predicate).map { PatchLineID(hunk: hunk.id, line: $0.id) }
    })
}

@Test(arguments: [["-old"], ["+new"], ["-old", "+new"], ["+new", "+extra"]])
func selectedLinesApplyOnlyTheChosenChanges(_ chosen: [String]) async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "one\nold\nthree\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Prepare")
    let working = "one\nnew\nextra\nthree\n"
    try f.write("readme.txt", working)
    var file = try #require(try await f.repo.snapshot().changes.first)
    var diff = try await f.repo.diff(file, staged: false)
    let selection = select(diff) { chosen.contains($0.text) }
    try await f.repo.stageLines(file, renderedDiff: diff, selection: selection, reverse: false)
    let expected = "one\n" + (chosen.contains("-old") ? "" : "old\n") + (chosen.contains("+new") ? "new\n" : "") + (chosen.contains("+extra") ? "extra\n" : "") + "three\n"
    #expect(try await f.git(["show", ":readme.txt"]).text == expected)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == working)
    file = try #require(try await f.repo.snapshot().changes.first)
    diff = try await f.repo.diff(file, staged: true)
    try await f.repo.stageLines(file, renderedDiff: diff, selection: PatchDocument(diff).selectableLines, reverse: true)
    #expect(try await f.git(["show", ":readme.txt"]).text == "one\nold\nthree\n")
}

@Test func unstageOneLinePreservesOtherStagedChangesAndRejectsStaleDiff() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "one\nold\nthree\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Prepare")
    try f.write("readme.txt", "one\nnew\nthree\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    var file = try #require(try await f.repo.snapshot().changes.first)
    let diff = try await f.repo.diff(file, staged: true)
    try await f.repo.stageLines(file, renderedDiff: diff, selection: select(diff) { $0.text == "+new" }, reverse: true)
    #expect(try await f.git(["show", ":readme.txt"]).text == "one\nthree\n")
    await #expect(throws: GitFailure.self) { try await f.repo.stageLines(file, renderedDiff: diff, selection: PatchDocument(diff).selectableLines, reverse: true) }
    file = try #require(try await f.repo.snapshot().changes.first)
    let unstaged = try await f.repo.diff(file, staged: false)
    try f.write("readme.txt", "external edit\n")
    await #expect(throws: GitFailure.self) { try await f.repo.stageLines(file, renderedDiff: unstaged, selection: PatchDocument(unstaged).selectableLines, reverse: false) }
}

@Test func lineStagingNewAndDeletedFilesPreservesWorktreeAndMissingNewline() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let path = "new \"file\" ü.txt"
    try f.write(path, "first\nlast")
    var file = try #require(try await f.repo.snapshot().changes.first)
    var diff = try await f.repo.diff(file, staged: false)
    try await f.repo.stageLines(file, renderedDiff: diff, selection: select(diff) { $0.text == "+last" }, reverse: false)
    #expect(try await f.git(["show", ":" + path]).text == "last")
    file = try #require(try await f.repo.snapshot().changes.first)
    diff = try await f.repo.diff(file, staged: true)
    try await f.repo.stageLines(file, renderedDiff: diff, selection: PatchDocument(diff).selectableLines, reverse: true)
    #expect(try await f.repo.snapshot().changes[0].isUntracked)
    #expect(try String(contentsOf: f.url.appendingPathComponent(path), encoding: .utf8) == "first\nlast")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Track new file")
    try FileManager.default.removeItem(at: f.url.appendingPathComponent(path))
    file = try #require(try await f.repo.snapshot().changes.first)
    diff = try await f.repo.diff(file, staged: false)
    try await f.repo.stageLines(file, renderedDiff: diff, selection: select(diff) { $0.text == "-first" }, reverse: false)
    #expect(try await f.git(["show", ":" + path]).text == "last")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    file = try #require(try await f.repo.snapshot().changes.first)
    diff = try await f.repo.diff(file, staged: true)
    try await f.repo.stageLines(file, renderedDiff: diff, selection: select(diff) { $0.text == "-last" }, reverse: true)
    #expect(try await f.git(["show", ":" + path]).text == "last")
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent(path).path))
}

@Test func selectedLinesAcrossHunksKeepCorrectOffsets() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let original = (1...80).map { "line \($0)" }.joined(separator: "\n") + "\n"
    try f.write("readme.txt", original)
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Prepare")
    try f.write("readme.txt", original.replacingOccurrences(of: "line 2\n", with: "new early\nextra early\n").replacingOccurrences(of: "line 70\n", with: "new late\n"))
    var file = try #require(try await f.repo.snapshot().changes.first)
    var diff = try await f.repo.diff(file, staged: false)
    try await f.repo.stageLines(file, renderedDiff: diff, selection: select(diff) { $0.text == "+extra early" || $0.text == "-line 70" }, reverse: false)
    #expect(try await f.git(["show", ":readme.txt"]).text == original.replacingOccurrences(of: "line 2\n", with: "line 2\nextra early\n").replacingOccurrences(of: "line 70\n", with: ""))
    file = try #require(try await f.repo.snapshot().changes.first)
    diff = try await f.repo.diff(file, staged: true)
    try await f.repo.stageLines(file, renderedDiff: diff, selection: PatchDocument(diff).selectableLines, reverse: true)
    #expect(try await f.git(["show", ":readme.txt"]).text == original)
}

@Test func splitRowsAlignReplacementsWithoutLosingLines() {
    let document = DiffDocument("@@ -1,4 +1,5 @@\n context\n-old\n+new\n+extra\n tail\n-end\n+finish")
    let rows = SplitDiffRow.align(Array(document.lines.dropFirst()))
    #expect(rows.count == 5)
    #expect(rows[1].left?.text == "-old" && rows[1].right?.text == "+new")
    #expect(rows[2].left == nil && rows[2].right?.text == "+extra")
    #expect(rows.compactMap(\.left).filter { $0.kind == .deletion }.count == 2)
    #expect(rows.compactMap(\.right).filter { $0.kind == .addition }.count == 3)
}

@Test func conflictParserPreservesDiff3CRLFAndUnresolvedRegions() throws {
    let text = "top\r\n<<<<<<< HEAD\r\nours\r\n||||||| base\r\nbase\r\n=======\r\ntheirs\r\n>>>>>>> branch\r\nend\r\n<<<<<<< HEAD\r\na\r\n=======\r\nb\r\n>>>>>>> next\r\n"
    let document = ConflictDocument(text)
    #expect(document.regions.count == 2 && document.regions[0].base == "base\r\n")
    let first = document.resolving(0, with: .both)
    #expect(first.hasPrefix("top\r\nours\r\ntheirs\r\nend\r\n"))
    let last = ConflictDocument(first).resolving(0, with: .incoming)
    #expect(!ConflictDocument(last).hasMarkers && last.hasSuffix("b\r\n"))
    #expect(ConflictDocument("<<<<<<< unclosed\nkeep\n").hasMarkers)
}

private func conflictedFixture(_ action: GitRepository.Integration = .merge) async throws -> Fixture {
    let f = try await Fixture.make()
    do {
        try await f.repo.createBranch("incoming")
        try f.write("readme.txt", "incoming\n")
        try await f.repo.stage(try await f.repo.snapshot().changes)
        try await f.repo.commit(message: "Incoming")
        let hash = try await f.repo.snapshot().commits[0].hash
        try await f.repo.switchBranch("main")
        try f.write("readme.txt", "current\n")
        try await f.repo.stage(try await f.repo.snapshot().changes)
        try await f.repo.commit(message: "Current")
        if action == .rebase { try await f.repo.switchBranch("incoming") }
        do { try await f.repo.integrate(action, revision: action == .rebase ? "refs/heads/main" : action == .merge ? "refs/heads/incoming" : hash) }
        catch is GitFailure { }
        return f
    } catch { f.clean(); throw error }
}

@Test(arguments: [GitRepository.Integration.merge, .rebase, .cherryPick])
func resolveConflictThenContinueIntegration(_ action: GitRepository.Integration) async throws {
    let f = try await conflictedFixture(action); defer { f.clean() }
    let conflict = try await f.repo.conflict("readme.txt")
    #expect(conflict.canEdit && conflict.version(2)?.text == "current\n" && conflict.version(3)?.text == "incoming\n")
    let result = ConflictDocument(try #require(conflict.text)).resolving(0, with: .both)
    try await f.repo.resolveConflict(conflict, resolution: .edited(result + "manual edit\n"))
    #expect(!(try await f.repo.snapshot().changes.contains(where: \.isConflicted)))
    #expect(try await f.git(["show", ":readme.txt"]).text == "current\nincoming\nmanual edit\n")
    try await f.repo.continueOperation()
    #expect(try await f.repo.currentOperation() == .none)
    let head = try await f.repo.snapshot().commits[0]
    #expect(!(try await f.repo.detail(head).message.contains("# Conflicts:")))
}

@Test func conflictResolutionRejectsMarkersAndStaleWorktreeOrIndex() async throws {
    let f = try await conflictedFixture(); defer { f.clean() }
    let conflict = try await f.repo.conflict("readme.txt")
    await #expect(throws: GitFailure.self) { try await f.repo.resolveConflict(conflict, resolution: .edited(try #require(conflict.text))) }
    try f.write("readme.txt", "outside editor\n")
    await #expect(throws: GitFailure.self) { try await f.repo.resolveConflict(conflict, resolution: .edited("clobber\n")) }
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "outside editor\n")
    let updated = try await f.repo.conflict("readme.txt")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    await #expect(throws: GitFailure.self) { try await f.repo.resolveConflict(updated, resolution: .version(3)) }
}

@Test func modifyDeleteConflictCanAcceptDeletion() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("deleted")
    _ = try await f.git(["rm", "readme.txt"])
    try await f.repo.commit(message: "Delete file")
    try await f.repo.switchBranch("main")
    try f.write("readme.txt", "modified\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Modify file")
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(.merge, revision: "refs/heads/deleted") }
    let conflict = try await f.repo.conflict("readme.txt")
    #expect(conflict.version(3) == nil)
    try await f.repo.resolveConflict(conflict, resolution: .version(3))
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("readme.txt").path))
    try await f.repo.continueOperation()
    #expect(try await f.repo.currentOperation() == .none)
}

@Test func binaryConflictAcceptsExactIncomingBytes() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await f.repo.createBranch("binary")
    try Data([0, 1, 2, 3]).write(to: f.url.appendingPathComponent("readme.txt"))
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Incoming binary")
    try await f.repo.switchBranch("main")
    try Data([0, 4, 5]).write(to: f.url.appendingPathComponent("readme.txt"))
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "Current binary")
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(.merge, revision: "refs/heads/binary") }
    let conflict = try await f.repo.conflict("readme.txt")
    #expect(!conflict.canEdit)
    try await f.repo.resolveConflict(conflict, resolution: .version(3))
    #expect(try Data(contentsOf: f.url.appendingPathComponent("readme.txt")) == Data([0, 1, 2, 3]))
    #expect(try await f.git(["show", ":readme.txt"]).data == Data([0, 1, 2, 3]))
}

@Test func lineStagingPreservesCRLFAndRejectsStructuralModeChanges() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("readme.txt", "one\r\nold\r\ntail\r\n")
    try await f.repo.stage(try await f.repo.snapshot().changes)
    try await f.repo.commit(message: "CRLF base")
    try f.write("readme.txt", "one\r\nnew\r\ntail\r\n")
    let file = try #require(try await f.repo.snapshot().changes.first)
    let diff = try await f.repo.diff(file, staged: false)
    try await f.repo.stageLines(file, renderedDiff: diff, selection: PatchDocument(diff).selectableLines, reverse: false)
    #expect(try await f.git(["show", ":readme.txt"]).text == "one\r\nnew\r\ntail\r\n")
    let structural = "diff --git a/a b/a\nold mode 100644\nnew mode 100755\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n"
    #expect(throws: GitFailure.self) { try PatchDocument(structural).selectedPatch([PatchLineID(hunk: 0, line: 1)], reverse: false) }
}

@Test func conflictResolutionPreservesExecutableModeAndRefusesSymlinkWrites() async throws {
    let f = try await conflictedFixture(); defer { f.clean() }
    let url = f.url.appendingPathComponent("readme.txt")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    let snapshot = try await f.repo.conflict("readme.txt")
    try await f.repo.resolveConflict(snapshot, resolution: .edited("resolved\n"))
    #expect(try await f.git(["ls-files", "--stage", "--", "readme.txt"]).text.hasPrefix("100755"))
    try await f.repo.abortOperation()
    await #expect(throws: GitFailure.self) { try await f.repo.integrate(.merge, revision: "refs/heads/incoming") }
    let conflict = try await f.repo.conflict("readme.txt")
    let outside = f.url.deletingLastPathComponent().appendingPathComponent("GitPico-outside-\(UUID().uuidString)")
    try Data("keep me\n".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
    await #expect(throws: GitFailure.self) { try await f.repo.resolveConflict(conflict, resolution: .version(3)) }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "keep me\n")
}
