import Foundation
import Testing
@testable import GitCore

private func selected(_ diff: String, matching text: Set<String>) -> Set<PatchLineID> {
    Set(PatchDocument(diff).hunks.flatMap { hunk in
        DiffDocument(hunk.text).lines.compactMap { line in
            (line.kind == .addition || line.kind == .deletion) && text.contains(String(line.text.dropFirst())) ? PatchLineID(hunk: hunk.id, line: line.id) : nil
        }
    })
}

@Test(arguments: ["\n", "\r\n"]) func stashSelectedLinesPreserveOtherLinesIndexAndLocalWork(newline: String) async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let base = ["spacing = 12", "radius = 8", "title = Welcome"].joined(separator: newline)
    try f.write("readme.txt", base); try await f.git(["add", "."]); try await f.repo.commit(message: "Line baseline")
    try f.write("readme.txt", ["spacing = 14", "radius = 8", "title = Hello"].joined(separator: newline))
    try await f.repo.saveStash(message: "Two replacements")
    let stash = try #require(try await f.repo.stashList().first)
    let file = try #require(try await f.repo.stashDetail(stash).files.first)
    let diff = try await f.repo.stashFileDiff(stash, file: file)
    let lines = selected(diff, matching: ["spacing = 12" + (newline == "\r\n" ? "\r" : ""), "spacing = 14" + (newline == "\r\n" ? "\r" : "")])
    try #require(lines.count == 2)
    try f.write("unrelated.txt", "local work\n")
    let index = try await f.git(["write-tree"]).text
    try await f.repo.applyStashLines(stash, file: file, renderedDiff: diff, selection: lines)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == ["spacing = 14", "radius = 8", "title = Welcome"].joined(separator: newline))
    #expect(try await f.git(["write-tree"]).text == index)
    #expect(try String(contentsOf: f.url.appendingPathComponent("unrelated.txt"), encoding: .utf8) == "local work\n")
    #expect(try await f.repo.stashList().first?.hash == stash.hash)
    await #expect(throws: GitFailure.self) { try await f.repo.applyStashLines(stash, file: file, renderedDiff: diff + "stale", selection: lines) }
}

@Test func stashLinesCanPartiallyCreateAndDeleteFiles() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("new[1].txt", "first\nsecond")
    try await f.repo.saveStash(message: "New file")
    let stash = try #require(try await f.repo.stashList().first), file = try #require(try await f.repo.stashDetail(stash).files.first)
    let diff = try await f.repo.stashFileDiff(stash, file: file)
    try await f.repo.applyStashLines(stash, file: file, renderedDiff: diff, selection: selected(diff, matching: ["second"]))
    #expect(try String(contentsOf: f.url.appendingPathComponent("new[1].txt"), encoding: .utf8) == "second")
    #expect(try await f.git(["ls-files", "--", "new[1].txt"]).text.isEmpty)
    try f.write("readme.txt", "original\nsecond\n"); try await f.git(["add", "readme.txt"]); try await f.repo.commit(message: "Two lines")
    try FileManager.default.removeItem(at: f.url.appendingPathComponent("readme.txt"))
    var options = StashSaveOptions(); options.paths = ["readme.txt"]
    let removed = try await f.repo.saveStash(options), removedFile = try #require(try await f.repo.stashDetail(removed).files.first)
    let deletion = try await f.repo.stashFileDiff(removed, file: removedFile)
    try await f.repo.applyStashLines(removed, file: removedFile, renderedDiff: deletion, selection: selected(deletion, matching: ["second"]))
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\n")
}

@Test func stashLinesAcrossChunksRejectInvalidOrConflictingSelection() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let base = (1...60).map { "line \($0)" }.joined(separator: "\n") + "\n"
    try f.write("readme.txt", base); try await f.git(["add", "."]); try await f.repo.commit(message: "Long file")
    try f.write("readme.txt", base.replacingOccurrences(of: "line 2\n", with: "changed 2\n").replacingOccurrences(of: "line 55\n", with: "changed 55\n"))
    try await f.repo.saveStash(message: "Separated chunks")
    let stash = try #require(try await f.repo.stashList().first), file = try #require(try await f.repo.stashDetail(stash).files.first)
    let diff = try await f.repo.stashFileDiff(stash, file: file)
    try #require(PatchDocument(diff).hunks.count == 2)
    await #expect(throws: GitFailure.self) { try await f.repo.applyStashLines(stash, file: file, renderedDiff: diff, selection: [PatchLineID(hunk: 999, line: 999)]) }
    try f.write("readme.txt", base.replacingOccurrences(of: "line 55\n", with: "external 55\n"))
    await #expect(throws: GitFailure.self) { try await f.repo.applyStashLines(stash, file: file, renderedDiff: diff, selection: selected(diff, matching: ["line 2", "changed 2", "line 55", "changed 55"])) }
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == base.replacingOccurrences(of: "line 55\n", with: "external 55\n"))
    try f.write("readme.txt", base)
    try await f.repo.applyStashLines(stash, file: file, renderedDiff: diff, selection: selected(diff, matching: ["line 2", "changed 2", "line 55", "changed 55"]))
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8).contains("changed 55"))
}
