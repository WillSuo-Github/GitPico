import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@MainActor private struct RelatedAppFixture {
    let root: URL
    let repository: GitRepository
    let store: RepositoryStore
    static func make() async throws -> RelatedAppFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-related-app-\(UUID())")
        let url = root.appendingPathComponent("Repo")
        let repository = try await GitRepository.create(at: urlWithParent(url))
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await GitProcess.run(["config", key, value], at: url) }
        try Data("original\n".utf8).write(to: url.appendingPathComponent("readme"))
        _ = try await GitProcess.run(["add", "."], at: url); _ = try await GitProcess.run(["commit", "-qm", "Initial"], at: url)
        let store = RepositoryStore(library: RepositoryLibrary(file: root.appendingPathComponent("library.json"), legacy: []))
        store.toolPreferences = ExternalToolPreferences(file: root.appendingPathComponent("tools.json"))
        await store.open(url)
        return RelatedAppFixture(root: root, repository: repository, store: store)
    }
    static func urlWithParent(_ url: URL) throws -> URL { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); return url }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test @MainActor func relatedRepositoryActionsReviewBeforeWritingAndRejectOldTokens() async throws {
    let f = try await RelatedAppFixture.make(); defer { f.clean() }
    let items = f.store.quickActionItems(files: [])
    let worktree = try #require(items.first { $0.id == "command:Add Worktree" })
    f.store.runQuickAction(worktree, repositoryToken: f.store.repositoryToken)
    guard case .create = f.store.worktreeRequest?.action else { Issue.record("Expected a worktree review"); return }
    #expect(try await f.repository.managedWorktrees().count == 1)
    let request = try #require(f.store.worktreeRequest)
    let plan = try await f.repository.previewWorktreeCreation(destination: f.root.appendingPathComponent("Linked"), mode: .new, branch: "feature")
    f.store.repositoryToken = UUID()
    f.store.applyWorktreePlan(plan, request: request, openAfter: false)
    #expect(!FileManager.default.fileExists(atPath: plan.destination.path))
    #expect(f.store.error?.contains("repository changed") == true)
    f.store.error = nil; f.store.submoduleRequest = nil
    let module = try #require(items.first { $0.id == "command:Add Submodule" })
    f.store.runQuickAction(module, repositoryToken: UUID())
    #expect(f.store.submoduleRequest == nil)
    f.store.runQuickAction(module, repositoryToken: f.store.repositoryToken)
    guard case .add = f.store.submoduleRequest?.action else { Issue.record("Expected a submodule review"); return }
    f.store.navigate(.worktrees); f.store.navigate(.submodules); f.store.navigate(.worktrees)
    #expect(f.store.destination == .worktrees)
}

@Test @MainActor func relatedRepositoryListsAndQuickOpenReuseCurrentStore() async throws {
    let f = try await RelatedAppFixture.make(); defer { f.clean() }
    let record = try await f.repository.createWorktree(try await f.repository.previewWorktreeCreation(destination: f.root.appendingPathComponent("Linked"), mode: .new, branch: "feature"))
    await f.store.loadRelatedRepositories()
    #expect(f.store.worktrees.count == 2 && f.store.submodules.isEmpty)
    let item = try #require(f.store.quickActionItems(files: []).first { $0.id == "worktree:" + record.id })
    let oldToken = f.store.repositoryToken
    f.store.runQuickAction(item, repositoryToken: oldToken)
    await f.store.operationTask?.value
    #expect(!f.store.isBusy)
    #expect(f.store.snapshot?.root.path == record.path && f.store.snapshot?.branch == "feature")
    #expect(f.store.repositoryToken != oldToken && f.store.worktrees.count == 2)
    #expect(f.store.destination == .workingCopy && f.store.error == nil)
    #expect(f.store.library.document.repositories.count == 2)
}

@Test @MainActor func worktreeListSelectionOnlyPreviewsAndNativeActionOpensAvailableTrees() async throws {
    let f = try await RelatedAppFixture.make(); defer { f.clean() }
    let linked = try await f.repository.createWorktree(try await f.repository.previewWorktreeCreation(destination: f.root.appendingPathComponent("Linked"), mode: .detached))
    let missing = try await f.repository.createWorktree(try await f.repository.previewWorktreeCreation(destination: f.root.appendingPathComponent("Missing"), mode: .detached))
    try FileManager.default.removeItem(atPath: missing.path)
    await f.store.loadRelatedRepositories()
    f.store.navigate(.worktrees)
    let token = f.store.repositoryToken
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.contentView = NSHostingView(rootView: WorktreesView(store: f.store))
    defer { window.contentView = nil; window.close() }
    func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { findTable($0) }.first
    }
    let deadline = ContinuousClock.now + .seconds(5)
    var nativeTable: NSTableView?
    while ContinuousClock.now < deadline {
        window.contentView?.layoutSubtreeIfNeeded()
        nativeTable = window.contentView.flatMap { findTable($0) }
        if nativeTable?.numberOfRows == f.store.worktrees.count { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let table = try #require(nativeTable)
    let missingRow = try #require(f.store.worktrees.firstIndex { $0.id == missing.id })
    let linkedRow = try #require(f.store.worktrees.firstIndex { $0.id == linked.id })
    #expect(table.doubleAction != nil)
    #expect(window.makeFirstResponder(table))
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    let trace = GitCommandTrace()
    await GitCommandTrace.$current.withValue(trace) {
        for row in [linkedRow, missingRow, 0, linkedRow, missingRow] {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
            #expect(table.selectedRow == row)
            #expect(f.store.repositoryToken == token && !f.store.isBusy && f.store.operationTask == nil)
        }
    }
    #expect(await trace.samples.isEmpty, "Previewing a worktree must not read or open its repository.")
    table.keyDown(with: enter)
    try await Task.sleep(for: .milliseconds(20))
    #expect(f.store.repositoryToken == token && f.store.operationTask == nil && f.store.error == nil)
    table.selectRowIndexes(IndexSet(integer: linkedRow), byExtendingSelection: false)
    try await Task.sleep(for: .milliseconds(20))
    table.keyDown(with: enter)
    try await Task.sleep(for: .milliseconds(20))
    await f.store.operationTask?.value
    #expect(f.store.snapshot?.root.path == linked.path && f.store.repositoryToken != token)
    #expect(f.store.error == nil && !f.store.isBusy)
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}

@Test @MainActor func malformedSubmoduleConfigurationKeepsRepositoryUsable() async throws {
    let f = try await RelatedAppFixture.make(); defer { f.clean() }
    let root = await f.repository.root
    try Data("[submodule broken\n".utf8).write(to: root.appendingPathComponent(".gitmodules"))
    // A malformed configuration is isolated to the submodule browser, not a failed repository open.
    await f.store.loadRelatedRepositories()
    #expect(f.store.submoduleError != nil && f.store.worktrees.count == 1)
    #expect(f.store.snapshot != nil && f.store.error == nil)
    try FileManager.default.removeItem(at: root.appendingPathComponent(".gitmodules"))
    await f.store.loadRelatedRepositories()
    #expect(f.store.submoduleError == nil && f.store.submodules.isEmpty)
}

@Test @MainActor func administrationRoutesRequireReviewAndRejectOldRepositoryTokens() async throws {
    let f = try await RelatedAppFixture.make(); defer { f.clean() }
    let record = try await f.repository.createWorktree(try await f.repository.previewWorktreeCreation(destination: f.root.appendingPathComponent("Linked"), mode: .detached))
    f.store.relatedAdministration(.worktrees([record]))
    let request = try #require(f.store.relatedAdministrationRequest)
    #expect(try await f.repository.managedWorktrees().first { $0.id == record.id }?.locked == nil)
    let plan = try await f.repository.previewWorktreeBatch([record], operation: .lock)
    f.store.repositoryToken = UUID()
    f.store.runRelatedBatch(plan, request: request)
    #expect(!f.store.isBusy && f.store.relatedBatchProgress == nil && f.store.error?.contains("repository changed") == true)
    #expect(try await f.repository.managedWorktrees().first { $0.id == record.id }?.locked == nil)
    f.store.error = nil
    let action = try #require(f.store.quickActionItems(files: []).first { $0.id == "command:Management Backups" })
    f.store.runQuickAction(action, repositoryToken: f.store.repositoryToken)
    guard case .backups = f.store.relatedAdministrationRequest?.action else { Issue.record("Expected Management Backups"); return }
}

@Test @MainActor func administrationBatchPublishesProgressAndReloadsInBackground() async throws {
    let f = try await RelatedAppFixture.make(); defer { f.clean() }
    let first = try await f.repository.createWorktree(try await f.repository.previewWorktreeCreation(destination: f.root.appendingPathComponent("First"), mode: .detached))
    let second = try await f.repository.createWorktree(try await f.repository.previewWorktreeCreation(destination: f.root.appendingPathComponent("Second"), mode: .detached))
    f.store.relatedAdministration(.worktrees([first, second]))
    let request = try #require(f.store.relatedAdministrationRequest)
    let plan = try await f.repository.previewWorktreeBatch([first, second], operation: .lock, value: "Store batch")
    f.store.runRelatedBatch(plan, request: request)
    #expect(f.store.isBusy && f.store.relatedBatchProgress?.state == "prepared")
    let deadline = Date().addingTimeInterval(80)
    while f.store.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    #expect(f.store.error == nil && !f.store.isBusy && f.store.relatedBatchTask == nil)
    #expect(f.store.relatedBatchProgress?.state == "completed")
    #expect(f.store.worktrees.filter { !$0.isMain }.allSatisfy { $0.locked == "Store batch" })
    #expect(try await f.repository.relatedBatchReports().first?.items.count == 2)
}

@Test @MainActor func administrationRestoreValidatesTokenAndRepopulatesWorktreeList() async throws {
    let f = try await RelatedAppFixture.make(); defer { f.clean() }
    let path = f.root.appendingPathComponent("Linked")
    let record = try await f.repository.createWorktree(try await f.repository.previewWorktreeCreation(destination: path, mode: .detached))
    try await f.repository.removeWorktree(record)
    let backup = try #require(try await f.repository.relatedManagementBackups().first)
    let plan = try await f.repository.previewRelatedManagementRestore(backup)
    f.store.relatedAdministration(.backups)
    let stale = try #require(f.store.relatedAdministrationRequest)
    f.store.repositoryToken = UUID()
    f.store.restoreManagementBackup(plan, request: stale)
    #expect(!FileManager.default.fileExists(atPath: path.path) && f.store.error != nil)
    f.store.error = nil; f.store.relatedAdministration(.backups)
    f.store.restoreManagementBackup(plan, request: try #require(f.store.relatedAdministrationRequest))
    let deadline = Date().addingTimeInterval(80)
    while f.store.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    #expect(f.store.worktrees.count == 2 && f.store.error == nil)
    #expect(FileManager.default.fileExists(atPath: path.appendingPathComponent("readme").path))
    #expect(try await f.repository.relatedManagementBackups().first?.state == "restored")
}

@Test @MainActor func infrastructureReviewsWorkFromWelcomeAndRejectStaleMigrationRequests() async throws {
    let f = try await RelatedAppFixture.make(); defer { f.clean() }
    let welcome = RepositoryStore(library: f.store.library)
    welcome.infrastructure(.repair)
    #expect(welcome.infrastructureRequest?.mode == .repair && welcome.snapshot == nil)
    welcome.isBusy = true; welcome.infrastructure(.move)
    #expect(welcome.infrastructureRequest?.mode == .repair)
    let items = f.store.quickActionItems(files: [])
    let move = try #require(items.first { $0.id == "command:Move Main Repository" })
    f.store.runQuickAction(move, repositoryToken: f.store.repositoryToken)
    let request = try #require(f.store.infrastructureRequest)
    #expect(request.mode == .move)
    let destination = f.root.appendingPathComponent("Moved")
    let plan = try await f.repository.previewMainRepositoryMigration(to: destination)
    f.store.repositoryToken = UUID()
    f.store.migrateMain(plan, request: request)
    #expect(!FileManager.default.fileExists(atPath: destination.path) && !f.store.isBusy)
    #expect(f.store.error?.contains("repository changed") == true)
}

@Test @MainActor func extensionQuickActionsOpenSettingsAndRequireConfigurationBeforeStartingTopics() async throws {
    let f = try await RelatedAppFixture.make(); defer { f.clean() }
    let items = f.store.quickActionItems(files: [])
    let lfs = try #require(items.first { $0.id == "command:Git LFS" })
    let flow = try #require(items.first { $0.id == "command:Git Flow" })
    #expect(items.contains { $0.id == "command:Start Git Flow Feature" } == false)
    f.store.runQuickAction(lfs, repositoryToken: f.store.repositoryToken)
    #expect(f.store.settingsTab == "Git LFS" && f.store.destination == .repositorySettings)
    f.store.runQuickAction(flow, repositoryToken: f.store.repositoryToken)
    #expect(f.store.settingsTab == "Git Flow" && f.store.destination == .repositorySettings)
    await Task.yield()
    let refreshDeadline = Date().addingTimeInterval(20)
    while f.store.isBusy && Date() < refreshDeadline { try await Task.sleep(for: .milliseconds(20)) }
    let plan = try await f.repository.previewGitFlowConfiguration(GitFlowConfiguration())
    f.store.manageFlow(.configure)
    f.store.applyFlow(plan, request: try #require(f.store.flowRequest))
    let deadline = Date().addingTimeInterval(20)
    while f.store.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(f.store.flowConfiguration != nil && f.store.error == nil && !f.store.isBusy)
    let start = try #require(f.store.quickActionItems(files: []).first { $0.id == "command:Start Git Flow Feature" })
    f.store.runQuickAction(start, repositoryToken: UUID())
    guard case .configure = f.store.flowRequest?.action else { Issue.record("A stale quick action changed the flow request"); return }
    f.store.runQuickAction(start, repositoryToken: f.store.repositoryToken)
    guard case .start(.feature) = f.store.flowRequest?.action else { Issue.record("Expected reviewed feature creation"); return }
    #expect(try await f.repository.headPosition().branch == "refs/heads/main")
}

@Test @MainActor func extensionMutationRequestsRejectStaleRepositorySessions() async throws {
    let f = try await RelatedAppFixture.make(); defer { f.clean() }
    let flow = try await f.repository.previewGitFlowConfiguration(GitFlowConfiguration())
    let lfs = try await f.repository.previewLFSChange(.track("*.bin", filename: false, source: ".gitattributes"))
    f.store.manageFlow(.configure); f.store.manageLFS(.change(.track("*.bin", filename: false, source: ".gitattributes")))
    let flowRequest = try #require(f.store.flowRequest), lfsRequest = try #require(f.store.lfsRequest)
    f.store.repositoryToken = UUID()
    f.store.applyFlow(flow, request: flowRequest)
    f.store.applyLFS(lfs, request: lfsRequest)
    #expect(!f.store.isBusy && f.store.error?.contains("repository changed") == true)
    let root = await f.repository.root
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitattributes").path))
    #expect(try await f.repository.gitFlowConfiguration() == nil)
    #expect(try await f.repository.references().contains { $0.name == "develop" } == false)
}

@Test @MainActor func lfsStoreEnableRefreshesNativeSettingsStateWithoutOpeningWindows() async throws {
    let f = try await RelatedAppFixture.make(); defer { f.clean() }
    let plan = try await f.repository.previewLFSChange(.enable(installHook: false))
    f.store.manageLFS(.change(.enable(installHook: false)))
    let request = try #require(f.store.lfsRequest)
    f.store.applyLFS(plan, request: request)
    let deadline = Date().addingTimeInterval(20)
    while f.store.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!f.store.isBusy && f.store.error == nil)
    #expect(f.store.lfsState?.enabled == true && f.store.lfsChanges.count == 1)
    let root = await f.repository.root
    #expect(f.store.snapshot?.root == root)
}
