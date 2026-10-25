import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RENDER_COMPONENTS"] == "1", "Explicit offscreen component capture only."))
@MainActor func renderHistoryRowsWithoutWindows() throws {
    let fields = [String(repeating: "a", count: 40), String(repeating: "b", count: 40), "Pico Team", "pico@example.invalid", "1792756900", "Keep branch previews responsive while browsing history", "HEAD -> feature/navigation, tag: v1, main", ""]
    let commit = try #require(GitParser.commits(Data((fields.joined(separator: "\0") + "\n").utf8)).first)
    let graph = CommitGraph.layout([commit])[commit.hash]
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_COMPONENT_OUTPUT"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
        let content = VStack(alignment: .leading, spacing: 8) {
            CommitRow(commit: commit, graph: graph, graphWidth: 29, selected: false)
            CommitRow(commit: commit, graph: graph, graphWidth: 29, selected: true)
                .background(Color(nsColor: .selectedContentBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            CommitRow(commit: commit, graph: graph, graphWidth: 29, selected: true)
                .environment(\.controlActiveState, .inactive)
                .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            CommitRow(commit: commit, graph: graph, graphWidth: 29, compact: true, selected: false)
            CommitRow(commit: commit, graph: nil, graphWidth: 0, showGraph: false, selected: false)
        }.padding(12).frame(width: 380).background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, scheme).environment(\.controlActiveState, .key)
        let renderer = ImageRenderer(content: content); renderer.scale = 2
        let cgImage = try #require(renderer.cgImage)
        let image = NSBitmapImageRep(cgImage: cgImage)
        let data = try #require(image.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("history-rows-\(scheme == .dark ? "dark" : "light").png"))
    }
    #expect(NSApplication.shared.windows.filter(\.isVisible).isEmpty)
    #expect(!NSApplication.shared.isActive)
}

@Test @MainActor func toolbarSearchBridgeUpdatesQueryAndCancelsObsoleteFocus() async {
    var query = "before"
    let coordinator = ToolbarSearchField.Coordinator(text: Binding(get: { query }, set: { query = $0 }))
    let field = NSSearchField()
    field.stringValue = "after"
    coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    #expect(query == "after")
    coordinator.focus(field, request: UUID())
    coordinator.focus(field, request: nil)
    await Task.yield()
    #expect(coordinator.lastFocusRequest == nil)
    #expect(!NSApplication.shared.isActive && NSApplication.shared.windows.filter(\.isVisible).isEmpty)
}
