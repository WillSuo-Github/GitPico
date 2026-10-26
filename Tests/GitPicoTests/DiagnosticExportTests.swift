import Foundation
import Testing
@testable import GitPico

@Test @MainActor func diagnosticsExcludeRepositoryNamesPathsMessagesAndCredentials() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    await f.store.open(await f.repository.root)
    f.store.commitSubject = "A confidential commit draft"
    let data = try DiagnosticExporter.data(store: f.store)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains(f.root.path) && !text.contains("A confidential commit draft"))
    #expect(!text.contains("github.com") && !text.contains("access_token") && !text.contains("refresh_token"))
    let value = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(value["format"] as? Int == 1 && value["repository"] != nil)
}
