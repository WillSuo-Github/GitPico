import AppKit
import GitCore
import SwiftUI

struct AICommitMessageSheet: View {
    let store: RepositoryStore
    @State private var preferences: AICommitPreferences
    @State private var session: AICommitSession
    @State private var settings: AICommitSettings
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
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Tool")
                    Picker("AI tool", selection: $settings.provider) { ForEach(AICommitProvider.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                }
                GridRow {
                    Text("Language")
                    Picker("Message language", selection: $settings.language) { ForEach(AICommitLanguage.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
                }
                GridRow {
                    Text("Executable")
                    HStack {
                        TextField("Auto-detect " + settings.provider.command, text: Binding(get: { settings.executableOverride }, set: { settings.executables[settings.provider.rawValue] = $0 }))
                            .textFieldStyle(.roundedBorder).accessibilityLabel("AI CLI executable path")
                        Button("Choose…", action: chooseExecutable)
                    }
                }
            }.disabled(busy)
            if let executable { Text(executable.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).truncationMode(.middle) }
            else { Label("CLI not found. Install it or choose its executable, then sign in using Terminal.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Pico.warning) }
            Text("The selected CLI uses its existing login and default model. Generating sends the staged diff to its configured AI service and may use subscription credits or incur API charges.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            HStack {
                Button("Close") { session.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if session.isGenerating { Button("Stop") { session.cancel() } }
                else {
                    Button(session.hasMessage ? "Generate Again" : "Generate Message", action: generate)
                        .disabled(executable == nil || store.isBusy || store.staged.isEmpty || busy)
                    Button(store.commitSubject.isEmpty && store.commitBody.isEmpty ? "Use Message" : "Replace Draft") {
                        Task { do { try await session.apply(to: store); dismiss() } catch { session.error = error.localizedDescription } }
                    }.buttonStyle(.borderedProminent).disabled(!session.hasMessage || busy || store.isBusy)
                }
            }
        }.padding(24).frame(width: 580)
            .onDisappear { session.cancel() }
    }
    private func generate() {
        guard let executable else { return }
        do { try preferences.save(settings); session.generate(in: store, settings: settings, executable: executable) }
        catch { session.error = error.localizedDescription }
    }
    private func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "Choose the " + settings.provider.command + " executable"
        if panel.runModal() == .OK, let url = panel.url { settings.executables[settings.provider.rawValue] = url.path }
    }
}
