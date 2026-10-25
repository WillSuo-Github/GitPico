import AppKit
import GitCore
import SwiftUI

struct ExternalToolSettingsView: View {
    @Bindable var preferences: ExternalToolPreferences
    @State private var diffPath = ""
    @State private var diffArguments = ""
    @State private var mergePath = ""
    @State private var mergeArguments = ""
    @State private var failure: String?
    @State private var saved = false
    @State private var loaded = ExternalToolSettings()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("External Diff & Merge Tools").font(.title2.bold())
            Text("Choose a command-line helper. FileMerge is included with Xcode. Tools run only when you click Launch Tool.").font(.callout).foregroundStyle(.secondary)
            GroupBox("Diff Tool") { fields(path: $diffPath, arguments: $diffArguments) }
            GroupBox("Merge Tool") { fields(path: $mergePath, arguments: $mergeArguments) }
            Text("Arguments are a JSON array. Use {local}, {remote}, {base}, {merged}. Each entry is passed as one argument; no shell is used.").font(.caption).foregroundStyle(.secondary)
            if let error = failure ?? preferences.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if saved { Text("Tool settings saved.").font(.caption).foregroundStyle(.green) }
            HStack {
                Button("Use FileMerge") { populate(ExternalToolSettings()) }
                Button("Reload") { preferences.reload(); populate(preferences.value); failure = nil }
                Spacer()
                Button("Save Settings") {
                    do {
                        let diff = try JSONDecoder().decode([String].self, from: Data(diffArguments.utf8))
                        let merge = try JSONDecoder().decode([String].self, from: Data(mergeArguments.utf8))
                        try preferences.save(ExternalToolSettings(diff: ExternalToolCommand(executable: diffPath, arguments: diff), merge: ExternalToolCommand(executable: mergePath, arguments: merge)), expected: loaded)
                        loaded = preferences.value
                        failure = nil; saved = true
                    } catch { failure = error.localizedDescription; saved = false }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(width: 690).task { populate(preferences.value) }
    }
    func populate(_ value: ExternalToolSettings) {
        loaded = preferences.value
        diffPath = value.diff.executable; mergePath = value.merge.executable
        diffArguments = String(decoding: (try? JSONEncoder().encode(value.diff.arguments)) ?? Data(), as: UTF8.self)
        mergeArguments = String(decoding: (try? JSONEncoder().encode(value.merge.arguments)) ?? Data(), as: UTF8.self); saved = false
    }
    func fields(path: Binding<String>, arguments: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Absolute executable path", text: path).textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.title = "Choose Tool Executable"; panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.treatsFilePackagesAsDirectories = true
                    panel.begin { result in if result == .OK, let url = panel.url { path.wrappedValue = url.path } }
                }
            }
            TextField("Arguments (JSON array)", text: arguments, axis: .vertical).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).lineLimit(2...4)
            Text(FileManager.default.isExecutableFile(atPath: path.wrappedValue) ? "Executable available" : "Executable not found; install its CLI helper or choose another path.").font(.caption2).foregroundStyle(.secondary)
        }.padding(7)
    }
}
