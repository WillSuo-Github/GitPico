import GitCore
import SwiftUI

struct ExternalToolSheet: View {
    @Bindable var store: RepositoryStore
    let request: ExternalToolRequest
    @Environment(\.dismiss) private var dismiss
    @State private var session: ExternalToolSession?
    @State private var sessions: [ExternalToolSession] = []
    @State private var selected: UUID?
    @State private var files: [String: URL] = [:]
    @State private var status: ExternalToolStatus?
    @State private var failure: String?
    @State private var loading = true
    @State private var launching = false
    @State private var showingSettings = false
    @State private var result = ""
    @State private var confirmingDelete = false
    @State private var loadGeneration = UUID()
    var browsingSessions: Bool { if case .sessions = request.action { true } else { false } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(session?.isMerge == true ? "External Merge" : browsingSessions ? "External Tool Sessions" : "External Comparison").font(.title2.bold()); Spacer(); Button("Tool Settings…") { showingSettings = true } }
            if !sessions.isEmpty {
                Picker("Saved Session", selection: $selected) { Text("Select a session").tag(nil as UUID?); ForEach(sessions) { item in Text(item.path + " · " + item.date.formatted(date: .numeric, time: .shortened)).tag(Optional(item.id)) } }.disabled(loading || launching)
            }
            if loading { ProgressView("Preparing tool files…").frame(maxWidth: .infinity, minHeight: 200) }
            if browsingSessions && !loading && sessions.isEmpty { ContentUnavailableView("No saved tool sessions", systemImage: "arrow.left.arrow.right", description: Text("Open an external comparison or merge from a file to create one.")) }
            if let session {
                Text(session.path).font(.headline).textSelection(.enabled)
                Text(session.title + " · " + session.head.branch).font(.callout).foregroundStyle(.secondary)
                Text(session.isMerge ? "The tool edits a separate result file. Save and close the tool, review the result, then apply it here. Applying also stages this file." : "The tool compares snapshot copies. Changes to these copies never update your working copy or index.").font(.callout).foregroundStyle(.secondary)
                if session.isMerge {
                    ScrollView { Text(result.isEmpty ? "Empty merge result" : result).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }.frame(height: 230).background(Color(nsColor: .textBackgroundColor))
                    Button("Reload Saved Result") { loadResult() }.disabled(status?.running == true)
                    if session.applied { Label("Result applied", systemImage: "checkmark.circle").foregroundStyle(.green) }
                } else {
                    ForEach(["local", "remote"], id: \.self) { side in
                        if let url = files[side] { LabeledContent(side.capitalized, value: url.path).font(.caption).textSelection(.enabled) }
                    }
                }
                if let status {
                    Text(status.running ? "Tool process is running" : status.exitCode.map { "Tool process exited with status \($0)" } ?? "No process tracked in this app session").font(.caption).foregroundStyle(.secondary)
                    if !status.diagnostics.isEmpty { Text(status.diagnostics).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled) }
                }
                Text("Session files survive app restarts. Close the external application before deleting a session, even if its CLI helper has already exited.").font(.caption).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                if session != nil { Button("Delete Session Files") { confirmingDelete = true }.disabled(status?.running == true || launching) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if let session {
                    Button("Launch Tool") { Task { await launch(session) } }.disabled(launching || status?.running == true || session.applied)
                    if session.isMerge { Button("Apply Result") { store.applyExternalResult(session.id, expectedResult: Data(result.utf8), request: request); dismiss() }.buttonStyle(.borderedProminent).disabled(failure != nil || session.applied || status?.running == true || launching || ConflictDocument(result).hasMarkers) }
                }
            }.disabled(store.isBusy || loading)
        }.padding(22).frame(width: 780)
        .task { await prepare() }
        .task(id: session?.id) {
            guard let session else { return }
            while !Task.isCancelled {
                status = await store.externalToolRunner.status(session.id)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: selected) { if let id = selected { Task { await load(id) } } }
        .confirmationDialog("Delete these tool copies and the saved result?", isPresented: $confirmingDelete) {
            Button("Delete Session Files", role: .destructive) { if let session { Task { await remove(session) } } }
        } message: { Text("This removes only the external tool session. Your working copy and index stay unchanged.") }
        .sheet(isPresented: $showingSettings) { VStack { ExternalToolSettingsView(preferences: store.toolPreferences); Button("Close") { showingSettings = false }.padding(.bottom) } }
    }
    func prepare() async {
        guard let repository = store.repository, request.repositoryToken == store.repositoryToken else { failure = "The repository changed."; loading = false; return }
        do {
            let item: ExternalToolSession?
            switch request.action {
            case .working(let path, let staged): item = try await repository.prepareExternalDiff(path: path, staged: staged)
            case .comparison(let left, let right, let path, let original): item = try await repository.prepareExternalComparison(left: left, right: right, path: path, originalPath: original)
            case .merge(let path): item = try await repository.prepareExternalMerge(path: path)
            case .sessions: sessions = try await repository.externalSessions(); item = nil
            }
            if let item { await load(item.id) }
        } catch { failure = error.localizedDescription }
        loading = false
    }
    func load(_ id: UUID) async {
        guard let repository = store.repository, request.repositoryToken == store.repositoryToken else { return }
        let generation = UUID(); loadGeneration = generation
        loading = true; failure = nil
        do {
            let item = try await repository.externalSession(id), urls = try await repository.externalFiles(item)
            let processStatus = await store.externalToolRunner.status(id)
            guard generation == loadGeneration, request.repositoryToken == store.repositoryToken, !Task.isCancelled else { return }
            session = item; files = urls; status = processStatus; loadResult()
        } catch { if generation == loadGeneration { failure = error.localizedDescription } }
        if generation == loadGeneration { loading = false }
    }
    func loadResult() {
        failure = nil
        guard let file = files["merged"] else { return }
        do {
            let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, attrs.fileSize ?? Int.max <= 1_048_576 else { throw GitFailure("Result is not a regular UTF-8 file under 1 MB.") }
            let data = try Data(contentsOf: file)
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw GitFailure("Result is not UTF-8 text.") }
            result = text
        } catch { failure = error.localizedDescription }
    }
    func launch(_ item: ExternalToolSession) async {
        guard request.repositoryToken == store.repositoryToken, !store.isBusy else { return }
        launching = true; failure = nil; defer { launching = false }
        do {
            guard store.toolPreferences.error == nil else { throw GitFailure("Reload valid external tool settings before launching.") }
            let command = item.isMerge ? store.toolPreferences.value.merge : store.toolPreferences.value.diff
            guard let repository = store.repository else { throw GitFailure("No repository is open.") }
            let validated = try await repository.externalFiles(item)
            try await store.externalToolRunner.launch(command, session: item, files: validated)
            status = await store.externalToolRunner.status(item.id)
        } catch { failure = error.localizedDescription }
    }
    func remove(_ item: ExternalToolSession) async {
        guard request.repositoryToken == store.repositoryToken, let repository = store.repository else { return }
        do {
            guard await store.externalToolRunner.status(item.id).running == false else { throw GitFailure("Close the tool before deleting its files.") }
            try await repository.deleteExternalSession(item.id); session = nil; files = [:]
            sessions = try await repository.externalSessions(); selected = nil
        } catch { failure = error.localizedDescription }
    }
}
