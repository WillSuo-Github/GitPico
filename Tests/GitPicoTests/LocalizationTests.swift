import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test @MainActor func diffLineActionDoesNotDependOnTranslatedChunkTitle() {
    let stage = ChunkDiffView(prepared: nil, actionTitle: "Chunk title from any language")
    let unstage = ChunkDiffView(prepared: nil, unstaging: true, actionTitle: "Chunk title from any language")
    #expect(stage.lineActionTitle.key == "Stage Lines")
    #expect(unstage.lineActionTitle.key == "Unstage Lines")
}

@Test @MainActor func localizedDisplayStatesKeepStoredIdentifiersSeparate() {
    #expect(operationStateTitle("needsRepair").key == "Repair Needed")
    #expect(operationStateTitle("restoring").key == "Restoring")
    #expect(networkCommandTitle("fetch").key == "Fetch")
    #expect(AICommitLanguage.chinese.rawValue == "Simplified Chinese")
}

@Test func appLayoutFollowsPreferredLanguageDirection() {
    #expect(AppLocalization.layoutDirection(for: "ar") == .rightToLeft)
    #expect(AppLocalization.layoutDirection(for: "he") == .rightToLeft)
    #expect(AppLocalization.layoutDirection(for: "de") == .leftToRight)
    #expect(AppLocalization.layoutDirection(for: "zh-Hans") == .leftToRight)
}

@Test func splitDividerTracksPointerInBothWritingDirectionsAndKeepsBounds() {
    #expect(splitColumnWidth(start: 320, translation: 50, minimum: 270, availableWidth: 1200, direction: .leftToRight) == 370)
    #expect(splitColumnWidth(start: 320, translation: 50, minimum: 270, availableWidth: 1200, direction: .rightToLeft) == 270)
    #expect(splitColumnWidth(start: 320, translation: -50, minimum: 270, availableWidth: 1200, direction: .rightToLeft) == 370)
    #expect(splitColumnWidth(start: 320, translation: -1000, minimum: 270, availableWidth: 1200, direction: .rightToLeft) == 850)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_CAPTURE_LOCALIZATIONS"] == "1", "Explicit offscreen localization capture only."))
@MainActor func renderLocalizedPanelsWithoutWindows() async throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_LOCALIZATION_OUTPUT"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = try await WorkingAppFixture.make(); defer { fixture.clean() }
    let preferences = AICommitPreferences(file: directory.appendingPathComponent("unused-preferences.json"))
    let request = PullReviewRequest(head: try await fixture.repository.headPosition(), upstream: "origin/main")
    let language = Bundle.main.preferredLocalizations.first ?? "en"
    try await capture(AICommitSettingsView(preferences: preferences), size: NSSize(width: 700, height: 750), name: "ai-settings")
    try await capture(PullReviewSheet(store: fixture.store, request: request), size: NSSize(width: 540, height: 600), name: "pull")
    #expect(!NSApplication.shared.isActive && NSApplication.shared.windows.filter(\.isVisible).isEmpty)

    func capture<Content: View>(_ content: Content, size: NSSize, name: String) async throws {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        window.contentView = NSHostingView(rootView: content.environment(\.colorScheme, .dark).environment(\.layoutDirection, AppLocalization.layoutDirection).background(.background))
        try await Task.sleep(for: .milliseconds(250))
        let view = try #require(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(language)-\(name).png"))
    }
}
