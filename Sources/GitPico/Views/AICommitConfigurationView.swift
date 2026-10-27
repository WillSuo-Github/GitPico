import AppKit
import GitCore
import SwiftUI

struct AICommitConfigurationView: View {
    @Binding var settings: AICommitSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Tool")
                    Picker("AI tool", selection: $settings.provider) {
                        ForEach(AICommitProvider.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Language")
                    Picker("Message language", selection: $settings.language) {
                        ForEach(AICommitLanguage.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Executable")
                    HStack {
                        TextField("Executable path", text: Binding(
                            get: { settings.executableOverride },
                            set: { settings.executables[settings.provider.rawValue] = $0 }
                        ), prompt: Text("Auto-detect " + settings.provider.command))
                            .labelsHidden().textFieldStyle(.roundedBorder).accessibilityLabel("AI CLI executable path")
                        Button("Choose…", action: chooseExecutable)
                    }
                }
            }
            if let executable = settings.provider.executable(override: settings.executableOverride) {
                Label("CLI found", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                Text(executable.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            } else {
                Label("CLI not found. Install it or choose its executable.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Pico.warning)
            }
            Text("Install and sign in to the selected CLI in Terminal first. Leave the executable field empty to use automatic detection.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Generation uses the CLI's existing login and default model. It sends the staged diff to its configured AI service and may use subscription credits or incur API charges. Nothing is sent when saving settings.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "Choose the " + settings.provider.command + " executable"
        if panel.runModal() == .OK, let url = panel.url { settings.executables[settings.provider.rawValue] = url.path }
    }
}
