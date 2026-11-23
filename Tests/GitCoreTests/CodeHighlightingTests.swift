import Foundation
import Testing
@testable import GitCore

@Test func codeHighlightingUsesUTF16AndFindsIndependentWordChanges() {
    let spans = CodeHighlighting.spans("let value = \"🌸\" // comment", path: "View.swift")
    #expect(spans.contains { $0.kind == .keyword && $0.range == NSRange(location: 0, length: 3) })
    #expect(spans.contains { $0.kind == .string })
    let (old, new) = CodeHighlighting.changedRanges("let 🐱 = first + last", "let 🐱 = newer + final")
    let a = "let 🐱 = first + last" as NSString, b = "let 🐱 = newer + final" as NSString
    #expect(Set(old.map { a.substring(with: $0) }) == ["first", "last"])
    #expect(Set(new.map { b.substring(with: $0) }) == ["newer", "final"])
    #expect(CodeHighlighting.matches("🌸 Hello hello", query: "HELLO") == [NSRange(location: 3, length: 5), NSRange(location: 9, length: 5)])
}

@Test func codeHighlightingDoesNotTreatStringsAsCommentsOrMarkUnchangedLines() {
    let spans = CodeHighlighting.spans("let url = \"https://example.invalid\" // note", path: "a.swift")
    #expect(spans.filter { $0.kind == .comment }.count == 1)
    #expect(CodeHighlighting.spans("plain text 123", path: "a.txt").isEmpty)
    let patch = DiffDocument("@@ -1,2 +1,2 @@\n-let count = 1\n+let count = 2\n same\n")
    let lines = CodeHighlighting.prepare(patch.lines, path: "a.swift")
    #expect(lines[1]?.changes.isEmpty == false && lines[2]?.changes.isEmpty == false)
    #expect(lines[3]?.changes.isEmpty == true)
    let long = String(repeating: "a", count: 20_000)
    #expect(CodeHighlighting.changedRanges(long, long + "b").1 == [NSRange(location: 20_000, length: 1)])
    #expect(CodeHighlighting.matches(long, query: "a").count == 1024)
    #expect(CodeHighlighting.contains(long + "end", query: "END"))
    let added = DiffDocument("@@ -1 +1,2 @@\n-old\n+new\n+let total = a + b\n").lines.filter { $0.kind == .addition }
    #expect(added.filter { CodeHighlighting.contains(CodeHighlighting.source($0), query: "+") }.count == 1)
}

@Test func codeHighlightingLexerHandlesCommentsEscapesNumbersAndHashLanguages() {
    let python = "value = \"not # comment\" + 'it\\'s' # real comment let 123"
    let pySpans = CodeHighlighting.spans(python, path: "script.py")
    #expect(pySpans.filter { $0.kind == .string }.count == 2)
    #expect(pySpans.filter { $0.kind == .comment }.count == 1)
    #expect(pySpans.filter { $0.kind == .keyword }.isEmpty)
    #expect(pySpans.filter { $0.kind == .number }.isEmpty)

    let swift = "let a = 12.34 + 56 // end /* not block */"
    let swiftSpans = CodeHighlighting.spans(swift, path: "App.swift")
    #expect(swiftSpans.map(\.kind) == [.keyword, .number, .number, .comment])

    let block = "let /* mid */ value = 123abc + foo123 + 7."
    let blockSpans = CodeHighlighting.spans(block, path: "App.swift")
    #expect(blockSpans.map(\.kind) == [.keyword, .comment, .number])

    let deletedDiff = "diff --git a/Old.swift b/Old.swift\n--- a/Old.swift\n+++ /dev/null\n@@ -1 +0,0 @@\n-+++ b/NotAHeader.swift\n"
    #expect(CodeHighlighting.path(in: deletedDiff) == "Old.swift")
}

@Test func diffDocumentAndPatchDocumentHandleTruncationCRLFAndBinaryHeaders() {
    #expect(DiffDocument("").lines.count == 1 && !DiffDocument("").isTruncated)
    #expect(DiffDocument("a\nb", limit: 2).lines.count == 2 && !DiffDocument("a\nb", limit: 2).isTruncated)
    #expect(DiffDocument("a\nb\n", limit: 2).isTruncated)
    #expect(DiffDocument("a\r\nb\r\n", limit: 10).lines.prefix(2).map(\.text) == ["a\r", "b\r"])

    let binary = PatchDocument("diff --git a/img.bin b/img.bin\nindex 111..222 100644\nBinary files a/img.bin and b/img.bin differ\n")
    #expect(binary.isBinary && binary.hunks.isEmpty && !binary.supportsChunkStaging)

    let textMentioningBinary = PatchDocument("diff --git a/View.swift b/View.swift\n--- a/View.swift\n+++ b/View.swift\n@@ -1 +1 @@\n-old\n+let check = diff.contains(\"Binary files \")\n")
    #expect(!textMentioningBinary.isBinary && textMentioningBinary.hunks.count == 1 && textMentioningBinary.supportsChunkStaging)
    #expect(textMentioningBinary.hunks[0].patch.hasPrefix("diff --git a/View.swift b/View.swift\n"))
    #expect(textMentioningBinary.hunks[0].patch.hasSuffix("+let check = diff.contains(\"Binary files \")\n"))
}
