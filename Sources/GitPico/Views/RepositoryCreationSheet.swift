import AppKit
import GitCore
import SwiftUI

struct RepositoryCreationRequest: Identifiable {
    let id = UUID()
    let clone: Bool
    var source: String = ""
    var name: String = ""
    var profileID: UUID? = nil

    func suggestedName(for source: String) -> String {
        guard clone else { return name }
        if source == self.source, !name.isEmpty { return name }

        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: Substring
        let isURL = source.range(of: "://").map { !source[..<$0.lowerBound].contains("/") } ?? false
        if isURL {
            guard let url = URLComponents(string: source), url.scheme == "file" || url.host?.isEmpty == false else { return "" }
            path = url.percentEncodedPath[...]
        } else if let prefix = source.prefixMatch(of: #/(?:[^/@:\s]+@)?(?:\[[^\]/]+\]|[^/:\s]+):/#) {
            path = source[prefix.range.upperBound...]
        } else {
            path = source[...]
        }

        let components = path.split(separator: "/")
        guard let last = components.last else { return "" }
        let component = last == ".git" ? (components.dropLast().last ?? "") : last
        let decoded = isURL ? (component.removingPercentEncoding ?? "") : String(component)
        let suggestion = decoded.hasSuffix(".git") ? String(decoded.dropLast(4)) : decoded
        return Self.isValidFolderName(suggestion) ? suggestion : ""
    }

    static func isValidFolderName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }
}

struct RepositoryCreationSheet: View {
    var store: RepositoryStore
    let request: RepositoryCreationRequest
    @State private var source = ""
    @State private var profileID: UUID?
    @State private var customName: String?
    @State private var recursive = false
    @State private var enableLFS = false
    @State private var downloadLFS = true
    @State private var allowLocalTransport = false
    @State private var parent = FileManager.default.homeDirectoryForCurrentUser
    @Environment(\.dismiss) private var dismiss
    init(store: RepositoryStore, request: RepositoryCreationRequest) {
        self.store = store
        self.request = request
        _source = State(initialValue: request.source)
        _profileID = State(initialValue: request.profileID)
    }
    private var name: String { customName ?? request.suggestedName(for: source) }
    var valid: Bool {
        RepositoryCreationRequest.isValidFolderName(name) &&
            (!request.clone || !source.isEmpty) &&
            (profileID == nil || store.authentication.profiles.contains { $0.id == profileID })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetTitle(request.clone ? "Clone Git Repository" : "Create Git Repository")
            if request.clone { TextField("Repository URL or local path", text: $source).textFieldStyle(.roundedBorder) }
            if request.clone {
                Picker("Authentication", selection: $profileID) {
                    Text("System Git / SSH").tag(nil as UUID?)
                    ForEach(store.authentication.profiles) { profile in Text(profile.label).tag(Optional(profile.id)) }
                }
                Text("Manage HTTPS accounts in Settings → Authentication. SSH uses your existing agent and host verification.").font(.caption).foregroundStyle(.secondary)
            }
            if request.clone {
                Toggle("Initialize submodules recursively", isOn: $recursive).toggleStyle(.checkbox)
                Toggle("Enable Git LFS for this clone", isOn: $enableLFS).toggleStyle(.checkbox)
                if enableLFS { Toggle("Download LFS objects now", isOn: $downloadLFS).toggleStyle(.checkbox); Text("Requires git-lfs. Turn off to clone pointer files and download objects later from Git LFS settings.").font(.caption).foregroundStyle(.secondary) }
                if recursive { Toggle("Allow local file transport for this clone and its submodules", isOn: $allowLocalTransport).toggleStyle(.checkbox).font(.caption) }
            }
            TextField("Local folder name", text: Binding(get: { name }, set: { customName = $0 })).textFieldStyle(.roundedBorder)
            HStack {
                LabeledContent("Parent", value: parent.path).lineLimit(1).truncationMode(.middle)
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.directoryURL = parent
                    panel.begin { if $0 == .OK, let url = panel.url { parent = url } }
                }
            }
            if !name.isEmpty { Text(parent.appendingPathComponent(name).path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.clone ? "Clone" : "Create") { store.createRepository(at: parent.appendingPathComponent(name, isDirectory: true), source: request.clone ? source : nil, recursive: recursive, allowLocalTransport: allowLocalTransport, lfs: enableLFS ? (downloadLFS ? .download : .pointersOnly) : .inherit, profileID: profileID); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!valid || store.isBusy)
            }
        }.padding(24).frame(width: 510)
    }
}
