import AppKit
import GitCore
import SwiftUI

struct AICommitMessageSheet: View {
    let store: RepositoryStore
    @State private var preferences: AICommitPreferences
    @State private var session: AICommitSession
    @State private var settings: AICommitSettings
    @State private var settingsSaved = false
    @Environment(\.dismiss) private var dismiss
    init(store: RepositoryStore, preferences: AICommitPreferences = .shared, session: AICommitSession = AICommitSession()) {
        self.store = store
        _preferences = State(initialValue: preferences); _settings = State(initialValue: preferences.value); _session = State(initialValue: session)
    }
    private var executable: URL? { settings.provider.executable(override: settings.executableOverride) }
    private var busy: Bool { session.isGenerating || session.isApplying }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle("AI Commit Message", icon: "sparkles")
            Text("Draft a message from your staged changes, review it, then use it in the commit editor.").font(.callout).foregroundStyle(.secondary)
            AICommitConfigurationView(settings: $settings).disabled(busy)
            if let reason = store.aiCommitUnavailableReason {
                Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            if session.hasMessage {
                TextField("Summary", text: $session.summary).textFieldStyle(.roundedBorder).accessibilityLabel("AI generated summary").disabled(busy)
                TextEditor(text: $session.body).font(.system(size: 12)).frame(height: 150).accessibilityLabel("AI generated description")
                    .disabled(busy)
            } else {
                VStack(spacing: 10) {
                    if session.isGenerating { ProgressView(); Text("Writing with \(settings.provider.title)…") }
                    else { Image(systemName: "sparkles").font(.title2); Text("Your generated message will appear here.") }
                }.font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 160)
            }
            if let error = session.error ?? preferences.error { Text(error).font(.caption).foregroundStyle(Pico.deletion).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if settingsSaved { Text("AI commit settings saved.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Close") { session.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Settings") {
                    do { try preferences.save(settings); session.error = nil; settingsSaved = true }
                    catch { session.error = error.localizedDescription }
                }.disabled(busy)
                Spacer()
                if session.isGenerating { Button("Stop") { session.cancel() } }
                else {
                    Button(session.hasMessage ? "Generate Again" : "Generate Message", action: generate)
                        .disabled(executable == nil || store.aiCommitUnavailableReason != nil || busy)
                    Button(store.commitSubject.isEmpty && store.commitBody.isEmpty ? "Use Message" : "Replace Draft") {
                        Task { do { try await session.apply(to: store); dismiss() } catch { session.error = error.localizedDescription } }
                    }.buttonStyle(.borderedProminent).disabled(!session.hasMessage || busy || store.isBusy)
                }
            }
        }.padding(24).frame(width: 580)
            .onDisappear { session.cancel() }
            .onChange(of: settings) { settingsSaved = false }
    }
    private func generate() {
        guard let executable else { return }
        do { try preferences.save(settings); session.generate(in: store, settings: settings, executable: executable) }
        catch { session.error = error.localizedDescription }
    }
}
