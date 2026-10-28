import AppKit
import GitCore
import SwiftUI

struct AICommitSettingsView: View {
    @State private var preferences: AICommitPreferences
    @State private var settings: AICommitSettings
    @State private var failure: String?
    @State private var showsExecutable = false
    init(preferences: AICommitPreferences = .shared) {
        _preferences = State(initialValue: preferences)
        _settings = State(initialValue: preferences.value)
    }
    private var provider: AICommitProvider { settings.resolvedProvider }
    private var instructions: Binding<String> {
        Binding(get: { settings.instructions ?? AICommitContext.defaultInstructions },
                set: { settings.instructions = $0 == AICommitContext.defaultInstructions ? nil : $0 })
    }
    var body: some View {
        Form {
            Section {
                Picker("Tool", selection: Binding(get: { provider }, set: { settings.provider = $0 })) {
                    ForEach(AICommitProvider.allCases) { option in
                        Text(settings.executable(for: option) == nil ? String(localized: "\(option.title) (not found)") : option.title).tag(option)
                    }
                }
                Picker("Language", selection: $settings.language) {
                    ForEach(AICommitLanguage.allCases) { Text($0.title).tag($0) }
                }
                if let executable = settings.executable(for: provider) {
                    LabeledContent("Executable") {
                        Text(executable.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    Label("\(provider.title) was not found. Install it and sign in from Terminal, or choose its executable.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Pico.warning).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Custom Executable", isExpanded: $showsExecutable) {
                    HStack {
                        TextField("Executable path", text: Binding(
                            get: { settings.executableOverride(for: provider) },
                            set: { settings.executables[provider.rawValue] = $0.isEmpty ? nil : $0 }
                        ), prompt: Text("Auto-detect \(provider.command)")).labelsHidden().accessibilityLabel("AI CLI executable path")
                        Button("Choose…", action: chooseExecutable)
                    }
                }
            } header: {
                Text("AI Commit Messages")
            } footer: {
                Text("Click AI beside the commit summary to write a message from the staged changes into the commit editor. Generation uses the CLI's existing login and default model and sends the staged diff to its AI service, which may use subscription credits or incur API charges.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: instructions).font(.system(size: 12, design: .monospaced)).frame(minHeight: 230).scrollContentBackground(.hidden)
                    .accessibilityLabel("Commit message prompt")
                HStack {
                    Text("GitPico adds the language, the staged diff and the reply format.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Default") { settings.instructions = nil }.disabled(settings.instructions == nil)
                }
            } header: {
                Text("Prompt")
            }
            if let error = failure ?? preferences.error {
                Text(error).font(.caption).foregroundStyle(Pico.deletion).textSelection(.enabled)
            }
        }.formStyle(.grouped)
            .onChange(of: settings) {
                do { try preferences.save(settings); failure = nil }
                catch { failure = error.localizedDescription }
            }
            .onChange(of: preferences.value) { if settings != preferences.value { settings = preferences.value } }
    }
    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the \(provider.command) executable")
        if panel.runModal() == .OK, let url = panel.url { settings.executables[provider.rawValue] = url.path }
    }
}
