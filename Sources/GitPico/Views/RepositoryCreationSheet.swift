import AppKit
import GitCore
import SwiftUI

struct RepositoryCreationRequest: Identifiable {
    let id = UUID()
    let clone: Bool
}

struct RepositoryCreationSheet: View {
    var store: RepositoryStore
    let request: RepositoryCreationRequest
    @State private var source = ""
    @State private var name = ""
    @State private var recursive = false
    @State private var enableLFS = false
    @State private var downloadLFS = true
    @State private var allowLocalTransport = false
    @State private var parent = FileManager.default.homeDirectoryForCurrentUser
    @Environment(\.dismiss) private var dismiss
    var valid: Bool { !name.isEmpty && !name.contains("/") && name != "." && name != ".." && (!request.clone || !source.isEmpty) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetTitle(request.clone ? "Clone Git Repository" : "Create Git Repository")
            if request.clone { TextField("Repository URL or local path", text: $source).textFieldStyle(.roundedBorder) }
            if request.clone {
                Toggle("Initialize submodules recursively", isOn: $recursive).toggleStyle(.checkbox)
                Toggle("Enable Git LFS for this clone", isOn: $enableLFS).toggleStyle(.checkbox)
                if enableLFS { Toggle("Download LFS objects now", isOn: $downloadLFS).toggleStyle(.checkbox); Text("Requires git-lfs. Turn off to clone pointer files and download objects later from Git LFS settings.").font(.caption).foregroundStyle(.secondary) }
                if recursive { Toggle("Allow local file transport for this clone and its submodules", isOn: $allowLocalTransport).toggleStyle(.checkbox).font(.caption) }
            }
            TextField("Local folder name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                LabeledContent("Parent", value: parent.path).lineLimit(1).truncationMode(.middle)
                Button("Choose…") {
                    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.directoryURL = parent
                    panel.begin { if $0 == .OK, let url = panel.url { parent = url } }
                }
            }
            if !name.isEmpty { Text(parent.appendingPathComponent(name).path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.clone ? "Clone" : "Create") { store.createRepository(at: parent.appendingPathComponent(name, isDirectory: true), source: request.clone ? source : nil, recursive: recursive, allowLocalTransport: allowLocalTransport, lfs: enableLFS ? (downloadLFS ? .download : .pointersOnly) : .inherit); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!valid || store.isBusy)
            }
        }.padding(24).frame(width: 510)
    }
}
