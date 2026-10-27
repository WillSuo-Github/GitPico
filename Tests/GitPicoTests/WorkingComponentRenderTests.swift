import AppKit
import Foundation
import GitCore
import SwiftUI
import Testing
@testable import GitPico

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RENDER_WORKING_COMPONENTS"] == "1", "Explicit windowless working component capture only."))
@MainActor func renderWorkingDiffDuringRefreshWithoutWindows() async throws {
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_WORKING_COMPONENT_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let prepared = PreparedPatch.make("diff --git a/Notes b/Notes\n--- a/Notes\n+++ b/Notes\n@@ -1,3 +1,3 @@\n Notes\n-old text\n+new text\n End\n")
    let window = RepositoryNativeWindow(tabID: UUID(), permitsPresentation: false)
    window.tabbingMode = .disallowed; window.styleMask = [.borderless]; window.contentMinSize = .zero
    window.appearance = NSAppearance(named: .aqua)
    defer { window.contentView = nil; window.close() }
    for loading in [false, true] {
        let view = ChunkDiffView(prepared: prepared, isLoading: loading, chunkAction: { _ in }, lineAction: { _ in })
            .frame(width: 840, height: 480).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.setFrame(NSRect(x: -10000, y: -10000, width: 840, height: 480), display: false)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let data = try #require(image.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent(loading ? "working-diff-refreshing.png" : "working-diff-ready.png"))
    }
    #expect(!NSApplication.shared.isActive && NSApplication.shared.windows.filter(\.isVisible).isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["GITPICO_RENDER_WORKING_COMPONENTS"] == "1", "Explicit windowless working component capture only."))
@MainActor func renderWorkingFileAndDiffRowsWithoutWindows() throws {
    let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GITPICO_WORKING_COMPONENT_OUTPUT"]))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let store = RepositoryStore(library: RepositoryLibrary(file: output.appendingPathComponent("unused-render-library.json"), legacy: []))
    let files = GitParser.status(Data(" M Sources/WorkingCopy.swift\0MM Docs/Notes.md\0M  README.md\0?? NewFile.txt\0UU Conflicted.txt\0".utf8))
    store.selectedWorkingFiles = ["Docs/Notes.md"]
    let patch = PreparedPatch.make("diff --git a/Notes b/Notes\n--- a/Notes\n+++ b/Notes\n@@ -1,3 +1,3 @@\n Notes\n-old text\n+new text\n End\n")
    let lines = try #require(patch.previews.first).lines
    for scheme in [ColorScheme.light, .dark] {
        let view = VStack(alignment: .leading, spacing: 0) {
            Text("Working Copy · File Rows").font(.system(size: 12, weight: .semibold)).padding(12)
            ForEach(files) { file in
                WorkingFileRow(store: store, file: file).padding(.horizontal, 10).frame(height: 30)
                    .background(store.selectedWorkingFiles.contains(file.path) ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
            Divider().padding(.top, 10)
            Text("Unified Diff · Selected Changed Line").font(.system(size: 12, weight: .semibold)).padding(12)
            ForEach(lines) { line in
                HStack(spacing: 0) {
                    if line.kind == .addition || line.kind == .deletion { LineSelectionButton(line: line, selected: line.kind == .addition, action: {}) }
                    else { Color.clear.frame(width: 25) }
                    DiffLineView(line: line, fontSize: 12)
                }.background(line.kind == .addition ? Color.accentColor.opacity(0.23) : .clear)
            }
        }.padding(12).frame(width: 640).background(Color(nsColor: .textBackgroundColor))
            .environment(\.colorScheme, scheme).environment(\.controlActiveState, .key)
        let renderer = ImageRenderer(content: view); renderer.scale = 2
        let image = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let data = try #require(image.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("working-components-\(scheme == .dark ? "dark" : "light").png"))
    }
    #expect(!NSApplication.shared.isActive && NSApplication.shared.windows.filter(\.isVisible).isEmpty)
}
