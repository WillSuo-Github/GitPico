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
