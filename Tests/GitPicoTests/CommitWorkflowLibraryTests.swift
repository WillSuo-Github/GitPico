import Foundation
import GitCore
import Testing
@testable import GitPico

@Test @MainActor func commitWorkflowLibraryPersistsProfilesTemplatesAndRefusesExternalChanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-workflows-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("workflows.json"), library = CommitWorkflowLibrary(file: root.appendingPathComponent("workflows.json"))
    let template = CommitTemplate(name: "Feature", text: "Feature summary\n\nDetails")
    let identity = CommitIdentityProfile(label: "Work", name: "Test Author", email: "work@example.invalid")
    try library.save(template: template); try library.save(identity: identity)
    let reopened = CommitWorkflowLibrary(file: file)
    #expect(reopened.templates == [template] && reopened.identities == [identity])
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try reopened.remove(template: template.id)
    #expect(throws: GitFailure.self) { try library.remove(identity: identity.id) }
    let current = CommitWorkflowLibrary(file: file)
    #expect(current.templates.isEmpty && current.identities == [identity])
    #expect(throws: GitFailure.self) { try current.save(identity: CommitIdentityProfile(label: "Bad", name: "Injected\nName", email: "x@example.invalid")) }
}

@Test @MainActor func corruptCommitWorkflowsArePreservedAndNeverOverwritten() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-workflows-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("workflows.json"), data = Data("{corrupt".utf8)
    try data.write(to: file)
    let library = CommitWorkflowLibrary(file: file)
    #expect(library.error != nil)
    #expect(throws: GitFailure.self) { try library.save(template: CommitTemplate(name: "Example", text: "Text")) }
    #expect(try Data(contentsOf: file) == data)
}

@Test @MainActor func preparedFixupRetainsExistingDraftAndAppliesOnlyLocalIdentity() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let selected = try #require(f.store.snapshot?.commits.first)
    f.store.commitSubject = "Existing draft"; f.store.commitBody = "Existing details"
    f.store.prepareFixup(selected)
    #expect(f.store.commitSubject == "fixup! " + selected.subject)
    #expect(f.store.commitBody == "Existing draft\n\nExisting details")
    #expect(f.store.destination == .workingCopy && !f.store.amend)
    f.store.saveIdentity(name: "Work Author", email: "work@example.invalid"); await f.finish()
    #expect(f.store.snapshot?.identity.name == "Work Author")
    #expect(try await GitProcess.run(["config", "--local", "user.email"], at: f.repository.root).text == "work@example.invalid\n")
}

@Test @MainActor func firstPushOpensReviewedPublicationWithoutWritingTheRemote() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let remote = f.root.appendingPathComponent("origin.git")
    _ = try await GitProcess.run(["init", "--bare", remote.path], at: f.repository.root)
    _ = try await GitProcess.run(["remote", "add", "origin", remote.path], at: f.repository.root)
    try await f.sync(); f.store.managedRemotes = try await f.repository.remoteConfigurations()
    f.store.sync(.push); await f.store.metadataTask?.value
    guard case .publish(let source, _, _, let force) = f.store.managementRequest?.action else { Issue.record("First Push did not open the publication review."); return }
    #expect(source?.isCurrent == true && source?.upstream.isEmpty == true && !force)
    #expect(f.store.operationTask == nil)
    let result = try await GitProcess.run(["show-ref", "--verify", "--quiet", "refs/heads/main"], at: remote, allowed: [0, 1])
    #expect(result.status == 1)
}
