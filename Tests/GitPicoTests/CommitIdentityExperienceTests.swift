import AppKit
import SwiftUI
import Testing
@testable import GitPico
import GitCore

@Test @MainActor func savedCommitIdentitySelectionAppliesOnlyToThisRepositoryAndNewCommits() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let other = try await WorkingAppFixture.make(); defer { other.clean() }
    let otherIdentity = try await other.repository.readIdentity()
    let library = CommitWorkflowLibrary(file: f.root.appendingPathComponent("identities.json"))
    let personal = CommitIdentityProfile(label: "Personal", name: "Personal Author", email: "personal@example.invalid")
    let work = CommitIdentityProfile(label: "Work", name: "Work Author", email: "work@example.invalid")
    try library.save(identity: personal); try library.save(identity: work)
    let globalBefore = try await GitProcess.run(["config", "--global", "--get-regexp", "^user\\.(name|email)$"], at: f.repository.root, allowed: [0, 1]).data
    let draft = RepositorySettingsDraft(); draft.load(try await f.repository.configuration())
    let before = try await f.repository.readIdentity()
    draft.general?.useIdentity(work)
    #expect(draft.hasChanges && work.matches(name: draft.general?.name ?? "", email: draft.general?.email ?? ""))
    let stillCurrent = try await f.repository.readIdentity()
    #expect(stillCurrent.name == before.name && stillCurrent.email == before.email, "Selection stays a draft until Save Changes.")
    #expect(await draft.save(in: f.store))
    #expect(try await f.repository.readIdentity().email == work.email)
    try await f.write("a.txt", "Commit with Work identity\n"); try await f.sync()
    f.store.stage(f.store.changes); await f.finish()
    f.store.commitSubject = "Identity acceptance"
    f.store.commit(); await f.finish()
    #expect(f.store.error == nil)
    #expect(try await GitProcess.run(["show", "-s", "--format=%an <%ae>", "HEAD"], at: f.repository.root).text == "Work Author <work@example.invalid>\n")
    f.store.commitSubject = "Keep next draft"
    f.store.saveIdentity(name: personal.name, email: personal.email); await f.finish()
    #expect(f.store.snapshot?.identity.email == personal.email && f.store.commitSubject == "Keep next draft")
    let stillOther = try await other.repository.readIdentity()
    #expect(stillOther.name == otherIdentity.name && stillOther.email == otherIdentity.email)
    #expect(try await GitProcess.run(["config", "--global", "--get-regexp", "^user\\.(name|email)$"], at: f.repository.root, allowed: [0, 1]).data == globalBefore)
    #expect(try await GitProcess.run(["show", "-s", "--format=%ae", "HEAD"], at: f.repository.root).text == work.email + "\n")
}

@Test @MainActor func editingAndDeletingSavedCommitIdentitiesDoesNotRewriteAppliedIdentity() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let file = f.root.appendingPathComponent("identities.json"), library = CommitWorkflowLibrary(file: f.root.appendingPathComponent("identities.json"))
    var work = CommitIdentityProfile(label: "Work", name: "Work Author", email: "work@example.invalid")
    try library.save(identity: work)
    f.store.saveIdentity(name: work.name, email: work.email); await f.finish()
    work.email = "new-work@example.invalid"; try library.save(identity: work)
    #expect(CommitWorkflowLibrary(file: file).identities == [work])
    #expect(try await f.repository.readIdentity().email == "work@example.invalid")
    try library.remove(identity: work.id)
    #expect(CommitWorkflowLibrary(file: file).identities.isEmpty)
    #expect(try await f.repository.readIdentity().email == "work@example.invalid")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_CAPTURE_IDENTITIES"] == "1", "Explicit offscreen identity captures."))
@MainActor func captureSavedCommitIdentitiesWithoutWindows() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_IDENTITIES_OUTPUT"]))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let library = CommitWorkflowLibrary(file: f.root.appendingPathComponent("identities.json"))
    let personal = CommitIdentityProfile(label: "Personal", name: "Alex Chen", email: "alex@example.invalid")
    let work = CommitIdentityProfile(label: "Work", name: "Alex Chen", email: "alex@company.invalid")
    try library.save(identity: personal); try library.save(identity: work)
    let draft = RepositorySettingsDraft(); draft.load(try await f.repository.configuration()); draft.general?.useIdentity(work)
    f.store.saveIdentity(name: work.name, email: work.email); await f.finish()
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.styleMask = [.borderless]; window.contentMinSize = .zero
    window.setFrame(NSRect(x: -10000, y: -10000, width: 850, height: 660), display: false)
    defer { window.contentView = nil; window.close() }
    for dark in [false, true] {
        try await capture(RepositorySettingsView(store: f.store, draft: draft, identityLibrary: library), size: NSSize(width: 850, height: 660), name: "repository-identity", dark: dark)
        try await capture(CommitIdentitiesView(library: library), size: NSSize(width: 600, height: 380), name: "saved-identities", dark: dark)
        try await capture(CommitComposer(store: f.store, workflows: library).frame(width: 340, height: 200), size: NSSize(width: 340, height: 200), name: "composer-identity", dark: dark)
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)

    func capture<Content: View>(_ content: Content, size: NSSize, name: String, dark: Bool) async throws {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: content.environment(\.controlActiveState, .key).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host; window.setContentSize(size)
        try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + (dark ? "-dark" : "") + ".png"))
    }
}
