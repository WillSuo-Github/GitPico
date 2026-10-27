import Foundation
import AppKit
import GitCore
import SwiftUI
import Testing
@testable import GitPico

private actor AICommitTestGenerator: AICommitGenerating {
    var started = false
    var prompt = ""
    let blocked: Bool
    var continuation: CheckedContinuation<Void, Never>?
    init(blocked: Bool = false) { self.blocked = blocked }
    func generate(provider: AICommitProvider, executable: URL, prompt: String) async throws -> AICommitMessage {
        self.prompt = prompt; started = true
        if blocked { await withCheckedContinuation { continuation = $0 } }
        return AICommitMessage(summary: "Describe staged changes", body: "Explain why they matter.")
    }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor private func aiCommitFixture() async throws -> WorkingAppFixture {
    let f = try await WorkingAppFixture.make()
    try await f.write("a.txt", "staged for AI\n")
    _ = try await GitProcess.run(["add", "a.txt"], at: f.repository.root)
    try await f.write("a.txt", "private unstaged text\n"); try await f.sync()
    return f
}
@MainActor private func awaitAIStart(_ generator: AICommitTestGenerator) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !(await generator.started) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await generator.started)
}

@Test @MainActor func aiCommitSuggestionRequiresExplicitApplicationAndKeepsRepositoryUntouched() async throws {
    let f = try await aiCommitFixture(); defer { f.clean() }
    f.store.commitSubject = "My draft"; f.store.commitBody = "My details"
    let head = try await f.repository.headPosition(), fingerprint = try await f.repository.aiCommitFingerprint()
    let generator = AICommitTestGenerator(), session = AICommitSession(generator: generator)
    session.generate(in: f.store, settings: AICommitSettings(), executable: URL(fileURLWithPath: "/stub")); await session.task?.value
    #expect(session.hasMessage && !session.isGenerating && session.error == nil)
    #expect(f.store.commitSubject == "My draft" && f.store.commitBody == "My details")
    let prompt = await generator.prompt
    #expect(prompt.contains("staged for AI") && !prompt.contains("private unstaged text"))
    session.summary = "Edited suggestion"
    try await session.apply(to: f.store)
    #expect(f.store.commitSubject == "Edited suggestion" && f.store.commitBody == "Explain why they matter.")
    #expect(try await f.repository.headPosition() == head)
    #expect(try await f.repository.aiCommitFingerprint() == fingerprint)
}

@Test @MainActor func aiCommitSuggestionRejectsChangedStagingAndNewDraftEdits() async throws {
    let f = try await aiCommitFixture(); defer { f.clean() }
    let session = AICommitSession(generator: AICommitTestGenerator())
    session.generate(in: f.store, settings: AICommitSettings(), executable: URL(fileURLWithPath: "/stub")); await session.task?.value
    f.store.commitSubject = "New manual draft"
    await #expect(throws: GitFailure.self) { try await session.apply(to: f.store) }
    #expect(f.store.commitSubject == "New manual draft")
    f.store.commitSubject = ""
    _ = try await GitProcess.run(["add", "a.txt"], at: f.repository.root)
    await #expect(throws: GitFailure.self) { try await session.apply(to: f.store) }
    #expect(f.store.commitSubject.isEmpty)
}

@Test @MainActor func aiCommitLateResultsCannotReplaceChangedIndexRepositoryOrCancelledSession() async throws {
    let f = try await aiCommitFixture(); defer { f.clean() }
    for action in ["index", "repository", "cancel"] {
        let generator = AICommitTestGenerator(blocked: true), session = AICommitSession(generator: generator)
        session.generate(in: f.store, settings: AICommitSettings(), executable: URL(fileURLWithPath: "/stub"))
        let task = session.task
        try await awaitAIStart(generator)
        if action == "index" { _ = try await GitProcess.run(["add", "a.txt"], at: f.repository.root) }
        else if action == "repository" { f.store.repositoryToken = UUID() }
        else { session.cancel() }
        await generator.release(); await task?.value
        #expect(!session.hasMessage && !session.isGenerating && f.store.commitSubject.isEmpty)
    }
}

@Test @MainActor func aiCommitPreferencesPersistProviderPathsAndLanguageAndProtectCorruptData() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-ai-preferences-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("ai.json"), preferences = AICommitPreferences(file: file)
    var settings = AICommitSettings(); settings.provider = .antigravity; settings.language = .chinese; settings.executables["antigravity"] = "/custom path/agy"
    try preferences.save(settings)
    #expect(AICommitPreferences(file: file).value == settings)
    let broken = Data("{broken".utf8); try broken.write(to: file)
    let corrupt = AICommitPreferences(file: file)
    #expect(corrupt.error != nil)
    #expect(throws: GitFailure.self) { try corrupt.save(settings) }
    #expect(try Data(contentsOf: file) == broken)
}

@Test @MainActor func aiCommitSetupBeforeStagingDoesNotInvokeCLIAndExplainsGenerationBlockers() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let preferences = AICommitPreferences(file: f.root.appendingPathComponent("ai.json"))
    var settings = AICommitSettings(); settings.provider = .claude; settings.language = .chinese
    settings.executables["claude"] = "/custom path/claude"
    try preferences.save(settings)
    #expect(AICommitPreferences(file: f.root.appendingPathComponent("ai.json")).value == settings)
    let generator = AICommitTestGenerator(), session = AICommitSession(generator: generator)
    session.generate(in: f.store, settings: preferences.value, executable: URL(fileURLWithPath: "/stub"))
    #expect(session.task == nil)
    #expect(await generator.started == false)
    #expect(session.error?.contains("Stage at least one change") == true)
    try await f.write("a.txt", "staged\n")
    _ = try await GitProcess.run(["add", "a.txt"], at: f.repository.root); try await f.sync()
    #expect(f.store.aiCommitUnavailableReason == nil)
    session.generate(in: f.store, settings: preferences.value, executable: URL(fileURLWithPath: "/stub"))
    await session.task?.value
    #expect(session.error == nil && session.hasMessage)
    #expect(await generator.started)
    let prompt = await generator.prompt
    #expect(prompt.contains("Simplified Chinese"))
}

@Test @MainActor func aiCommitGenerationExplainsConflictsEvenWhenOtherChangesAreStaged() async throws {
    let f = try await WorkingAppFixture.make(); defer { f.clean() }
    let branch = try await f.repository.headPosition().branch
    _ = try await GitProcess.run(["checkout", "-b", "ai-conflict"], at: f.repository.root)
    try await f.write("a.txt", "other branch\n")
    _ = try await GitProcess.run(["commit", "-am", "Change other branch"], at: f.repository.root)
    _ = try await GitProcess.run(["checkout", branch], at: f.repository.root)
    try await f.write("a.txt", "current branch\n")
    _ = try await GitProcess.run(["commit", "-am", "Change current branch"], at: f.repository.root)
    _ = try await GitProcess.run(["merge", "ai-conflict"], at: f.repository.root, allowed: [1])
    try await f.write("b.txt", "separately staged\n")
    _ = try await GitProcess.run(["add", "b.txt"], at: f.repository.root); try await f.sync()
    #expect(!f.store.staged.isEmpty && f.store.changes.contains(where: \.isConflicted))
    let generator = AICommitTestGenerator(), session = AICommitSession(generator: generator)
    session.generate(in: f.store, settings: AICommitSettings(), executable: URL(fileURLWithPath: "/stub"))
    #expect(session.error?.contains("Resolve and stage conflicted files") == true)
    #expect(session.task == nil)
    #expect(await generator.started == false)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RENDER_AI_COMMIT"] == "1", "Explicit offscreen AI commit UI capture only."))
@MainActor func renderAICommitEntryAndSuggestionWithoutWindows() async throws {
    let f = try await aiCommitFixture(); defer { f.clean() }
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_AI_COMMIT_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let preferences = AICommitPreferences(file: f.root.appendingPathComponent("ai-settings.json"))
    var session = AICommitSession(generator: AICommitTestGenerator())
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.tabbingMode = .disallowed; window.styleMask = [.borderless]; window.contentMinSize = .zero
    window.appearance = NSAppearance(named: .aqua)
    defer { window.contentView = nil; window.close() }
    for step in ["entry", "setup", "suggestion", "settings", "unstaged-entry", "unstaged-setup"] {
        if step == "unstaged-entry" {
            _ = try await GitProcess.run(["reset", "HEAD", "--", "a.txt"], at: f.repository.root)
            try await f.sync()
            session = AICommitSession(generator: AICommitTestGenerator())
        }
        if step == "suggestion" {
            session.generate(in: f.store, settings: AICommitSettings(), executable: URL(fileURLWithPath: "/stub")); await session.task?.value
        }
        let entry = step.hasSuffix("entry")
        let width: CGFloat = entry ? 340 : (step == "settings" ? 740 : 600)
        let height: CGFloat = entry ? 210 : (step == "settings" ? 570 : 760)
        let content = Group {
            if entry { CommitComposer(store: f.store) }
            else if step == "settings" { AICommitSettingsView(preferences: preferences) }
            else { AICommitMessageSheet(store: f.store, preferences: preferences, session: session) }
        }.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: content); window.contentView = host
        window.setFrame(NSRect(x: -10000, y: -10000, width: width, height: height), display: false)
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("ai-commit-" + step + ".png"))
    }
    #expect(!NSApp.isActive && NSApp.windows.filter(\.isVisible).isEmpty)
}
