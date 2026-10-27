import SwiftUI

struct AICommitSettingsView: View {
    @State private var preferences: AICommitPreferences
    @State private var settings: AICommitSettings
    @State private var failure: String?
    @State private var saved = false
    init(preferences: AICommitPreferences = .shared) {
        _preferences = State(initialValue: preferences)
        _settings = State(initialValue: preferences.value)
    }
    var body: some View {
        Form {
            Section("AI Commit Messages") {
                Text("Choose the tool used by the AI button beside the commit summary. You can configure it before staging changes.")
                    .font(.callout).foregroundStyle(.secondary)
                AICommitConfigurationView(settings: $settings)
            }
            Section {
                Text("Stage the changes you want to describe, click AI in the commit editor, then choose Generate Message. Review the suggestion and choose Use Message to fill the editor.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = failure ?? preferences.error {
                    Text(error).font(.caption).foregroundStyle(Pico.deletion).textSelection(.enabled)
                }
                if saved { Text("AI commit settings saved.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Save Settings") {
                        do { try preferences.save(settings); failure = nil; saved = true }
                        catch { failure = error.localizedDescription; saved = false }
                    }.buttonStyle(.borderedProminent)
                }
            }
        }.formStyle(.grouped)
            .onChange(of: settings) { saved = false }
            .onChange(of: preferences.value) {
                if settings != preferences.value { settings = preferences.value; saved = false }
            }
    }
}
