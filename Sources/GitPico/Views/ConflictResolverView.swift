import GitCore
import SwiftUI

struct ConflictResolverView: View {
    @Bindable var store: RepositoryStore
    let path: String
    @State private var snapshot: ConflictSnapshot?
    @State private var result = ""
    @State private var loadError: String?
    @State private var generation = 0
    @State private var showBase = false
    @State private var showReloadConfirmation = false
    var document: ConflictDocument { ConflictDocument(result) }

    var body: some View {
        VStack(spacing: 0) {
            FileTitleBar(path: path, subtitle: "Merge conflict", status: "Conflict") {
                if snapshot?.version(1) != nil { Toggle("Show Base", isOn: $showBase).toggleStyle(.button).controlSize(.small) }
                Button("External Merge…") { store.externalTool(.merge(path)) }.controlSize(.small).disabled(store.isBusy)
                Button { showReloadConfirmation = true } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Reload the conflict from Git").disabled(store.isBusy)
            }
            if let snapshot {
                if snapshot.operation == .rebase {
                    Label("During a rebase, Current is the branch being rebased onto and Incoming is the commit being replayed.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 0) {
                    if showBase { ConflictSourceView(title: "Base", stage: "stage 1", tint: .secondary, version: snapshot.version(1)); Divider() }
                    ConflictSourceView(title: "Current", stage: "stage 2", tint: Pico.modified, version: snapshot.version(2))
                    Divider()
                    ConflictSourceView(title: "Incoming", stage: "stage 3", tint: .purple, version: snapshot.version(3))
                }.frame(height: 210)
                Divider()
                if snapshot.canEdit {
                    if !document.regions.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 14) {
                                ForEach(document.regions) { region in
                                    HStack(spacing: 6) {
                                        Chip(text: "Conflict \(region.id + 1)", icon: "exclamationmark.triangle.fill", tint: Pico.deletion)
                                        Button("Use Current") { result = document.resolving(region.id, with: .current) }
                                        Button("Use Incoming") { result = document.resolving(region.id, with: .incoming) }
                                        Button("Use Both") { result = document.resolving(region.id, with: .both) }
                                        if region.base != nil { Button("Use Base") { result = document.resolving(region.id, with: .base) } }
                                    }
                                }
                            }.font(.system(size: 11)).controlSize(.small).padding(10)
                        }.background(.bar)
                        Divider()
                    }
                    HStack {
                        Text("Result").fontWeight(.semibold)
                        Spacer()
                        Text(document.hasMarkers ? (document.regions.isEmpty ? "Conflict markers remain · edit the result" : "\(document.regions.count) unresolved \(document.regions.count == 1 ? "block" : "blocks") · edit or choose a version") : "Ready to mark resolved").foregroundStyle(document.hasMarkers ? Pico.warning : Pico.addition)
                    }.font(.system(size: 11)).padding(.horizontal, 14).frame(height: 30).background(.bar)
                    TextEditor(text: $result).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                        .padding(8).accessibilityLabel("Conflict resolution result")
                } else {
                    EmptyPane(title: "Choose a complete version", subtitle: "Binary or large files cannot be edited here. Symbolic links and submodules require an external Git tool.", icon: "doc.badge.gearshape")
                }
                Divider()
                HStack(spacing: 10) {
                    Menu("Accept Entire File") {
                        Button(snapshot.version(2) == nil ? "Accept Current Deletion" : "Accept Current File") { store.resolveConflict(snapshot, resolution: .version(2)) }
                        Button(snapshot.version(3) == nil ? "Accept Incoming Deletion" : "Accept Incoming File") { store.resolveConflict(snapshot, resolution: .version(3)) }
                    }.fixedSize()
                    Spacer()
                    if snapshot.canEdit {
                        Button("Save & Mark Resolved") { store.resolveConflict(snapshot, resolution: .edited(result)) }
                            .buttonStyle(.borderedProminent).disabled(document.hasMarkers).keyboardShortcut("s", modifiers: .command)
                    }
                }.font(.system(size: 11)).controlSize(.small).padding(12).disabled(store.isBusy || !snapshot.versions.allSatisfy(\.isRegular))
                Text("Saving also stages this file. Draft edits stay available while switching files.").font(.caption2).foregroundStyle(.secondary).padding(.bottom, 8)
            } else if let loadError {
                EmptyPane(title: "Unable to load conflict", subtitle: loadError, icon: "exclamationmark.triangle")
            } else { ProgressView("Loading conflict versions…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: generation) {
            guard let repository = store.repository else { return }
            if let draft = store.conflictDrafts[path] { snapshot = draft.snapshot; result = draft.text; return }
            do {
                let loaded = try await repository.conflict(path)
                guard !Task.isCancelled else { return }
                snapshot = loaded; result = loaded.text ?? ""; loadError = nil
            } catch { guard !Task.isCancelled else { return }; loadError = error.localizedDescription }
        }
        .onChange(of: result) {
            if let snapshot { store.conflictDrafts[path] = ConflictDraft(snapshot: snapshot, text: result) }
        }
        .confirmationDialog("Reload the conflict and discard edits in this result?", isPresented: $showReloadConfirmation) {
            Button("Reload Conflict", role: .destructive) { store.conflictDrafts.removeValue(forKey: path); snapshot = nil; generation += 1 }
        }
    }
}

private struct ConflictSourceView: View {
    let title: String
    let stage: String
    let tint: Color
    let version: ConflictVersion?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).fontWeight(.semibold)
                Text(stage).foregroundStyle(.tertiary)
                Spacer()
                if let version { Text(String(version.object.prefix(8))).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary) }
            }
                .font(.system(size: 11)).padding(.horizontal, 12).frame(height: 29).background(tint.opacity(0.08)).overlay(alignment: .bottom) { Rectangle().fill(tint.opacity(0.4)).frame(height: 1) }
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Text(version.map { $0.text ?? "Binary or large file · \($0.data.count) bytes" } ?? "File deleted / absent in this version")
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(12)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }.defaultScrollAnchor(.topLeading)
            }
        }.frame(maxWidth: .infinity)
    }
}
