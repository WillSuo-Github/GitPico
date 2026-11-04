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
    @State private var showFullSources = false
    @State private var showReloadConfirmation = false
    @State private var restoredWarning: String?
    @State private var labels: ConflictLabels?
    @State private var focusedConflict = 0
    @State private var focusRequest = UUID()
    var document: ConflictDocument { ConflictDocument(result) }
    var region: ConflictRegion? { document.regions.first { $0.id == focusedConflict } ?? document.regions.first }
    var sourceHeight: CGFloat {
        guard !showFullSources, let region else { return 210 }
        let lines = [region.current, region.incoming, showBase ? region.base ?? "" : ""].map { $0.split(separator: "\n", omittingEmptySubsequences: false).count }.max() ?? 1
        return min(260, max(110, CGFloat(lines) * 15 + 48))
    }

    var body: some View {
        VStack(spacing: 0) {
            FileTitleBar(path: path, subtitle: String(localized: "Merge conflict"), status: "Conflict") {
                if snapshot?.version(1) != nil { Toggle("Show Base", isOn: $showBase).toggleStyle(.button).controlSize(.small) }
                Toggle("Full Sources", isOn: $showFullSources).toggleStyle(.button).controlSize(.small)
                    .help("Show complete source files instead of the selected conflict block.")
                Button("External Merge…") { store.externalTool(.merge(path)) }.controlSize(.small).disabled(store.isBusy)
                Button { showReloadConfirmation = true } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Reload the conflict from Git").disabled(store.isBusy)
            }
            if let snapshot {
                if let restoredWarning { Text(restoredWarning).font(.caption).foregroundStyle(Pico.warning).padding(10) }
                if let error = store.conflictDraftSaveError { Text("Draft not saved: \(error)").font(.caption).foregroundStyle(Pico.deletion).padding(8) }
                if snapshot.operation == .rebase {
                    Label("During a rebase, Current is the branch being rebased onto and Incoming is the commit being replayed.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 0) {
                    if showBase { ConflictSourceView(title: String(localized: "Base"), stage: "", tint: .secondary, version: snapshot.version(1), preview: showFullSources ? nil : region?.base); Divider() }
                    ConflictSourceView(title: labels?.current ?? String(localized: "Current"), stage: String(localized: "Current"), tint: Pico.modified, version: snapshot.version(2), preview: showFullSources ? nil : region?.current)
                    Divider()
                    ConflictSourceView(title: labels?.incoming ?? String(localized: "Incoming"), stage: String(localized: "Incoming"), tint: .purple, version: snapshot.version(3), preview: showFullSources ? nil : region?.incoming)
                }.frame(height: sourceHeight)
                Divider()
                if snapshot.canEdit {
                    if !document.regions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text("Conflict \((region?.id ?? 0) + 1) of \(document.regions.count)").fontWeight(.semibold)
                                Spacer()
                                Button { moveConflict(-1) } label: { Image(systemName: "chevron.up") }.help("Previous conflict").accessibilityLabel("Previous conflict")
                                Button { moveConflict(1) } label: { Image(systemName: "chevron.down") }.help("Next conflict").accessibilityLabel("Next conflict")
                            }
                            HStack(spacing: 8) {
                                Button("Use Current") { choose(.current) }.help(labels?.current ?? "")
                                Button("Use Incoming") { choose(.incoming) }.help(labels?.incoming ?? "")
                                Button("Use Both") { choose(.both) }
                                if region?.base != nil { Button("Use Base") { choose(.base) } }
                            }
                        }.font(.system(size: 12)).controlSize(.regular).padding(10).background(.bar).disabled(store.isBusy)
                        Divider()
                    }
                    HStack {
                        Text("Result").fontWeight(.semibold)
                        Spacer()
                        Text(document.hasMarkers ? (document.regions.isEmpty ? "Conflict markers remain · edit the result" : "\(document.regions.count) unresolved blocks · edit or choose a version") : "Ready to mark resolved").foregroundStyle(document.hasMarkers ? Pico.warning : Pico.addition)
                    }.font(.system(size: 11)).padding(.horizontal, 14).frame(height: 30).background(.bar)
                    ConflictResultEditor(text: $result, reveal: region?.original, focusRequest: focusRequest, disabled: store.isBusy)
                        .environment(\.layoutDirection, .leftToRight)
                } else {
                    EmptyPane(title: String(localized: "Choose a complete version"), subtitle: snapshot.versions.contains(where: { $0.mode == "160000" }) ? String(localized: "Accepting stages the selected Git object only. Nested directories and working files are preserved, including file/submodule type conflicts. Update the working copy separately after resolving.") : String(localized: "Choose Current or Incoming for binary files and symbolic links. Link targets are preserved without reading the target file."), icon: "doc.badge.gearshape")
                }
                Divider()
                HStack(spacing: 10) {
                    Menu(snapshot.versions.contains(where: { $0.mode == "160000" }) ? "Accept Index Version Only" : "Accept Entire File") {
                        Button(snapshot.version(2) == nil ? "Accept Current Deletion" : "Accept Current File") { store.resolveConflict(snapshot, resolution: .version(2)) }
                        Button(snapshot.version(3) == nil ? "Accept Incoming Deletion" : "Accept Incoming File") { store.resolveConflict(snapshot, resolution: .version(3)) }
                    }.fixedSize()
                    Spacer()
                    if snapshot.canEdit {
                        Button("Save & Mark Resolved") { store.resolveConflict(snapshot, resolution: .edited(result)) }
                            .buttonStyle(.borderedProminent).disabled(document.hasMarkers).keyboardShortcut("s", modifiers: .command)
                    }
                }.font(.system(size: 11)).controlSize(.small).padding(12).disabled(store.isBusy)
                Text("Saving also stages this file. Draft edits are automatically saved for recovery after restarting.").font(.caption2).foregroundStyle(.secondary).padding(.bottom, 8)
            } else if let loadError {
                EmptyPane(title: String(localized: "Unable to load conflict"), subtitle: loadError, icon: "exclamationmark.triangle")
            } else { ProgressView("Loading conflict versions…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: generation) {
            guard let repository = store.repository else { return }
            labels = try? await repository.conflictLabels()
            guard !Task.isCancelled else { return }
            if let draft = store.conflictDrafts[path] {
                snapshot = draft.snapshot; result = draft.text
                let current = try? await repository.conflict(path)
                guard !Task.isCancelled else { return }
                restoredWarning = current?.indexSignature == draft.snapshot.indexSignature && current?.workingData == draft.snapshot.workingData && current?.operation == draft.snapshot.operation
                    ? String(localized: "Recovered saved draft. Review it before marking the conflict resolved.")
                    : String(localized: "Git or this file changed since the draft was saved. Copy or export the draft before reloading; saving over changed content is blocked.")
                return
            }
            do {
                let loaded = try await repository.conflict(path)
                guard !Task.isCancelled else { return }
                snapshot = loaded; result = loaded.text ?? ""; loadError = nil
            } catch { guard !Task.isCancelled else { return }; loadError = error.localizedDescription }
        }
        .onChange(of: result) {
            if focusedConflict >= document.regions.count { focusedConflict = max(0, document.regions.count - 1) }
            if let snapshot { store.updateConflictDraft(snapshot, text: result) }
        }
        .confirmationDialog("Reload the conflict and discard edits in this result?", isPresented: $showReloadConfirmation) {
            Button("Reload Conflict", role: .destructive) { store.conflictDrafts.removeValue(forKey: path); snapshot = nil; restoredWarning = nil; loadError = nil; generation += 1 }
        }
    }
    private func moveConflict(_ offset: Int) {
        guard !document.regions.isEmpty else { return }
        focusedConflict = ((region?.id ?? 0) + offset + document.regions.count) % document.regions.count
        focusRequest = UUID()
    }
    private func choose(_ choice: ConflictChoice) {
        guard !store.isBusy, let region else { return }
        result = document.resolving(region.id, with: choice)
        focusedConflict = min(focusedConflict, max(0, document.regions.count - 1))
        focusRequest = UUID()
    }
}

private struct ConflictSourceView: View {
    let title: String
    let stage: String
    let tint: Color
    let version: ConflictVersion?
    var preview: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).fontWeight(.semibold).lineLimit(1).truncationMode(.middle).help(title)
                Text(stage).foregroundStyle(.secondary)
                Spacer()
            }
                .font(.system(size: 11)).padding(.horizontal, 12).frame(height: 29).background(tint.opacity(0.08)).overlay(alignment: .bottom) { Rectangle().fill(tint.opacity(0.4)).frame(height: 1) }
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Text(preview ?? version.map { $0.text ?? String(localized: "Binary or large file · \($0.data.count) bytes") } ?? String(localized: "File deleted / absent in this version"))
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(12)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }.defaultScrollAnchor(.topLeading)
            }
        }.frame(maxWidth: .infinity)
    }
}
