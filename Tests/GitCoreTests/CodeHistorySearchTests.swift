import Foundation
import Testing
@testable import GitCore

@Test func codeHistorySearchFindsAddedAndRemovedLiteralTextWithoutOptionInjection() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try Data("let value = \"--all [literal]\"\n".utf8).write(to: f.url.appendingPathComponent("code.swift"))
    try await f.git(["add", "."]); try await f.git(["commit", "-m", "Introduce value"])
    try Data("let value = \"other\"\n".utf8).write(to: f.url.appendingPathComponent("code.swift"))
    try await f.git(["commit", "-am", "Replace value"])
    try await f.git(["commit", "--allow-empty", "-m", "Unrelated"])
    var options = HistoryOptions(); options.query = "content:\"--all [literal]\" path:\"code.swift\""
    let page = try await f.repo.historyPage(at: f.repo.resolveHistory("HEAD"), options: options)
    #expect(Set(page.commits.map(\.subject)) == ["Introduce value", "Replace value"])
}
