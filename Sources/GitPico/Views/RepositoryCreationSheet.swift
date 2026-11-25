import AppKit
import GitCore
import SwiftUI

struct RepositoryCreationRequest: Identifiable {
    let id = UUID()
    let clone: Bool
    var source: String = ""
    var name: String = ""
    var profileID: UUID? = nil
    var parent: URL? = nil
    var recursive: Bool = false
    var enableLFS: Bool = false
    var downloadLFS: Bool = true
    var allowLocalTransport: Bool = false

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
        _recursive = State(initialValue: request.recursive)
        _enableLFS = State(initialValue: request.enableLFS)
        _downloadLFS = State(initialValue: request.downloadLFS)
        _allowLocalTransport = State(initialValue: request.allowLocalTransport)
        _parent = State(initialValue: request.parent ?? FileManager.default.homeDirectoryForCurrentUser)
    }
    private var name: String { customName ?? request.suggestedName(for: source) }
    private var destinationURL: URL? {
        guard RepositoryCreationRequest.isValidFolderName(name) else { return nil }
        return parent.appendingPathComponent(name, isDirectory: true)
    }
    private var destinationExists: Bool {
        destinationURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
    var valid: Bool {
        RepositoryCreationRequest.isValidFolderName(name) &&
            !destinationExists &&
            (!request.clone || !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if request.clone { sourceCard }
                destinationCard
                if request.clone { optionsCard }
            }
            .padding(22)
            Divider()
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: 540)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: request.clone ? "arrow.down.circle" : "plus.square.dashed")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(request.clone ? "Clone Git Repository" : "Create Git Repository")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text(request.clone
                    ? String(localized: "Download a repository to this Mac and open it in GitPico.")
                    : String(localized: "Initialize an empty Git repository in a new local folder."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption("Source")
            TextField("Repository URL or local path", text: $source)
                .textFieldStyle(.roundedBorder)
            Text("Manage HTTPS accounts in Settings → Authentication. SSH uses your existing agent and host verification.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption("Destination")
            HStack(spacing: 12) {
                RepositoryGlyph(name: name.isEmpty ? "Git" : name, size: 34)
                    .opacity(name.isEmpty ? 0.45 : 1)
                TextField("Local folder name", text: Binding(get: { name }, set: { customName = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(Pico.abbreviated(parent.path))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(parent.path)
                Spacer(minLength: 8)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.directoryURL = parent
                    panel.begin { if $0 == .OK, let url = panel.url { parent = url } }
                }
                .controlSize(.small)
            }
            if let destinationURL {
                HStack(spacing: 6) {
                    if destinationExists {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Pico.warning)
                        Text("A folder already exists at \(Pico.abbreviated(destinationURL.path)). Choose a new folder name.")
                            .font(.system(size: 11))
                            .foregroundStyle(Pico.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(Pico.abbreviated(destinationURL.path))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionCaption("Options")
            Toggle("Initialize submodules recursively", isOn: $recursive)
                .toggleStyle(.checkbox)
            if recursive {
                Toggle(isOn: $allowLocalTransport) {
                    Text("Allow local file transport for this clone and its submodules")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .padding(.leading, 20)
            }
            Toggle("Enable Git LFS for this clone", isOn: $enableLFS)
                .toggleStyle(.checkbox)
            if enableLFS {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Download LFS objects now", isOn: $downloadLFS)
                        .toggleStyle(.checkbox)
                    Text("Requires git-lfs. Turn off to clone pointer files and download objects later from Git LFS settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 20)
            }
        }
        .font(.system(size: 12.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(request.clone ? "Clone" : "Create") {
                store.createRepository(
                    at: parent.appendingPathComponent(name, isDirectory: true),
                    source: request.clone ? source.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                    recursive: recursive,
                    allowLocalTransport: allowLocalTransport,
                    lfs: enableLFS ? (downloadLFS ? .download : .pointersOnly) : .inherit,
                    profileID: source == request.source ? request.profileID : nil
                )
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!valid || store.isBusy)
        }
    }
}
