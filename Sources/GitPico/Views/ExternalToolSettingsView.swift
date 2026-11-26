import AppKit
import GitCore
import SwiftUI
import UniformTypeIdentifiers

struct ExternalToolSettingsView: View {
    @Bindable var preferences: ExternalToolPreferences
    @State private var catalog = ExternalAppCatalog.shared
    @State private var diffPath = ""
    @State private var diffArguments = ""
    @State private var mergePath = ""
    @State private var mergeArguments = ""
    @State private var failure: String?
    @State private var saved = false
    @State private var loaded = ExternalToolSettings()

    var body: some View {
        Form {
            Section {
                appRow(title: "Default Terminal", kind: .terminal)
                appRow(title: "Default Editor", kind: .editor)
            } header: {
                Text("Terminal & Editor")
            } footer: {
                Text("Installed terminals and editors are detected automatically. Choose any .app bundle to use a custom application.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Diff Tool").font(.subheadline.weight(.semibold))
                    fields(path: $diffPath, arguments: $diffArguments)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Merge Tool").font(.subheadline.weight(.semibold))
                    fields(path: $mergePath, arguments: $mergeArguments)
                }
                HStack {
                    Button("Use FileMerge") {
                        let defaults = ExternalToolSettings()
                        diffPath = defaults.diff.executable
                        mergePath = defaults.merge.executable
                        diffArguments = encodedArguments(defaults.diff.arguments)
                        mergeArguments = encodedArguments(defaults.merge.arguments)
                        saved = false
                    }
                    Button("Reload") {
                        catalog.refresh()
                        preferences.reload()
                        populate(preferences.value)
                        failure = nil
                    }
                    Spacer()
                    Button("Save Settings", action: saveDiffMergeSettings)
                        .buttonStyle(.borderedProminent)
                }
                if let error = failure ?? preferences.error {
                    Text(error).font(.caption).foregroundStyle(Pico.deletion).textSelection(.enabled)
                }
                if saved {
                    Text("Tool settings saved.").font(.caption).foregroundStyle(.green)
                }
            } header: {
                Text("External Diff & Merge Tools")
            } footer: {
                Text("Choose a command-line helper. FileMerge is included with Xcode. Arguments are a JSON array using {local}, {remote}, {base}, {merged}; no shell is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            catalog.refresh()
            populate(preferences.value)
        }
    }

    @ViewBuilder
    private func appRow(title: LocalizedStringKey, kind: ExternalAppKind) -> some View {
        let installed = catalog.installedApps(for: kind)
        let configuredPath = configuredAppPath(for: kind)
        let resolved = catalog.resolve(kind: kind, settings: preferences.value)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker(title, selection: appSelectionBinding(for: kind)) {
                    Text(automaticLabel(for: kind, installed: installed)).tag("")
                    if !installed.isEmpty {
                        Divider()
                        ForEach(installed) { app in
                            Text(app.name).tag(app.path)
                        }
                    }
                    if let configuredPath, !installed.contains(where: { $0.path == configuredPath }) {
                        Divider()
                        Text(customAppLabel(path: configuredPath, kind: kind)).tag(configuredPath)
                    }
                }
                Button("Choose…") { chooseApplication(for: kind) }
            }
            switch resolved {
            case .configured(let app), .automatic(let app):
                Text(app.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            case .missingConfigured(let path):
                Label("Application not found at \(path)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Pico.warning)
                    .lineLimit(2)
            case .unavailable:
                Text(kind == .terminal ? "No supported terminal detected. Choose an application." : "No supported editor detected. Choose an application.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func configuredAppPath(for kind: ExternalAppKind) -> String? {
        switch kind {
        case .terminal: preferences.value.terminalAppPath
        case .editor: preferences.value.editorAppPath
        }
    }

    private func appSelectionBinding(for kind: ExternalAppKind) -> Binding<String> {
        Binding(
            get: { configuredAppPath(for: kind) ?? "" },
            set: { saveAppPath($0.isEmpty ? nil : $0, for: kind) }
        )
    }

    private func automaticLabel(for kind: ExternalAppKind, installed: [InstalledExternalApp]) -> String {
        if let first = installed.first {
            return String(localized: "Automatic (\(first.name))")
        }
        return String(localized: "Automatic (None detected)")
    }

    private func customAppLabel(path: String, kind: ExternalAppKind) -> String {
        let url = URL(fileURLWithPath: path)
        let app = ExternalAppDiscovery.describeApp(at: url, kind: kind, environment: catalog.environment)
        if catalog.environment.fileExists(path) {
            return app.name
        }
        return String(localized: "\(app.name) (not found)")
    }

    private func chooseApplication(for kind: ExternalAppKind) {
        let panel = NSOpenPanel()
        panel.title = kind == .terminal
            ? String(localized: "Choose Default Terminal")
            : String(localized: "Choose Default Editor")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            saveAppPath(url.standardizedFileURL.path, for: kind)
        }
    }

    private func saveAppPath(_ path: String?, for kind: ExternalAppKind) {
        var updated = preferences.value
        let normalized = ExternalToolSettings.normalizedAppPath(path)
        switch kind {
        case .terminal:
            guard updated.terminalAppPath != normalized else { return }
            updated.terminalAppPath = normalized
        case .editor:
            guard updated.editorAppPath != normalized else { return }
            updated.editorAppPath = normalized
        }
        do {
            try preferences.save(updated, expected: loaded)
            loaded = preferences.value
            failure = nil
            saved = true
        } catch {
            failure = error.localizedDescription
            saved = false
        }
    }

    private func saveDiffMergeSettings() {
        do {
            let diff = try JSONDecoder().decode([String].self, from: Data(diffArguments.utf8))
            let merge = try JSONDecoder().decode([String].self, from: Data(mergeArguments.utf8))
            let updated = ExternalToolSettings(
                diff: ExternalToolCommand(executable: diffPath, arguments: diff),
                merge: ExternalToolCommand(executable: mergePath, arguments: merge),
                terminalAppPath: preferences.value.terminalAppPath,
                editorAppPath: preferences.value.editorAppPath
            )
            try preferences.save(updated, expected: loaded)
            loaded = preferences.value
            failure = nil
            saved = true
        } catch {
            failure = error.localizedDescription
            saved = false
        }
    }

    private func encodedArguments(_ arguments: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(arguments)) ?? Data(), as: UTF8.self)
    }

    func populate(_ value: ExternalToolSettings) {
        loaded = preferences.value
        diffPath = value.diff.executable; mergePath = value.merge.executable
        diffArguments = encodedArguments(value.diff.arguments)
        mergeArguments = encodedArguments(value.merge.arguments)
        saved = false
    }

    func fields(path: Binding<String>, arguments: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("", text: path, prompt: Text("Absolute executable path"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Absolute executable path")
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.title = String(localized: "Choose Tool Executable"); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.treatsFilePackagesAsDirectories = true
                    panel.begin { result in if result == .OK, let url = panel.url { path.wrappedValue = url.path } }
                }
            }
            TextField("", text: arguments, prompt: Text("Arguments (JSON array)"), axis: .vertical)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1...2)
                .accessibilityLabel("Arguments (JSON array)")
            Text(FileManager.default.isExecutableFile(atPath: path.wrappedValue) ? "Executable available" : "Executable not found; install its CLI helper or choose another path.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
