import GitCore
import SwiftUI

struct RemotePushSheet: View {
    let store: RepositoryStore
    let source: Reference?
    let remoteName: String?
    let destination: String?
    let force: Bool
    @State private var sourceID = ""
    @State private var remoteID = ""
    @State private var destinationName = ""
    @State private var urls: [String] = []
    @State private var pushURL = ""
    @State private var tracking = false
    @State private var lease = false
    @State private var advanced = false
    @State private var confirmation: RemotePushPreview?
    @State private var checking = false
    @State private var failure: String?
    @State private var confirmationTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    private var deleting: Bool { source == nil && destination != nil }
    private var selectedSource: Reference? { source ?? refs.first { $0.id == sourceID } }
    private var selectedRemote: RemoteConfiguration? { store.managedRemotes.first { $0.name == remoteID } }
    private var refs: [Reference] { (store.snapshot?.references ?? []).filter { $0.isLocal || $0.isTag } }
    private var revision: String { deleting ? destinationName : (selectedSource?.isTag == true ? "refs/tags/" : "refs/heads/") + destinationName }
    private var title: LocalizedStringResource {
        if deleting { return "Delete Remote Reference" }
        if lease { return "Force Push with Lease" }
        if selectedSource?.isTag == true { return "Push Tag" }
        return selectedSource?.upstream.isEmpty == true ? "Publish Branch" : "Push"
    }
    private var submitDisabled: Bool {
        store.isBusy || checking || selectedRemote == nil || pushURL.isEmpty || destinationName.isEmpty || (!deleting && selectedSource == nil)
    }
    private var actionTitle: LocalizedStringResource {
        deleting || lease ? "Continue" : selectedSource?.isLocal == true && selectedSource?.upstream.isEmpty == true ? "Publish" : "Push"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let confirmation {
                RemotePushConfirmation(preview: confirmation, busy: store.isBusy,
                                       back: { self.confirmation = nil },
                                       push: { store.runRemotePush(confirmation); dismiss() })
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    PushSheetHeading(title: title, icon: deleting ? "trash" : "arrow.up") {
                        if !deleting, let selectedSource, source != nil {
                            Label(selectedSource.name, systemImage: selectedSource.isTag ? "tag" : "arrow.triangle.branch")
                                .lineLimit(1).truncationMode(.middle).help(selectedSource.name)
                        }
                    }
                    fields.disabled(checking || store.isBusy)
                    if deleting {
                        Text("Deletes only this reference on the selected server. Existing local commits and references are retained.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let failure { Text(failure).font(.caption).foregroundStyle(Pico.deletion).textSelection(.enabled) }
                    HStack(spacing: 8) {
                        if checking {
                            ProgressView().controlSize(.small)
                            Text("Checking destination…").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        Button(actionTitle, action: submit).buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction).disabled(submitDisabled)
                    }
                }.padding(24)
            }
        }
        .frame(width: 460)
        .onAppear(perform: configure)
        .task(id: remoteID) {
            urls = []; pushURL = ""; failure = nil
            guard let remote = selectedRemote, let repo = store.repository else { return }
            do {
                let value = try await repo.effectivePushURLs(remote)
                guard !Task.isCancelled else { return }
                urls = value; pushURL = value.first ?? ""
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
        .onChange(of: store.repositoryToken) { confirmationTask?.cancel(); dismiss() }
        .onDisappear { confirmationTask?.cancel() }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Picker("Remote", selection: $remoteID) {
                    ForEach(store.managedRemotes) { Text($0.name).tag($0.name) }
                }
                if urls.count == 1 {
                    LabeledContent("") {
                        Text(pushURL).font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(pushURL)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !deleting {
                    if source == nil {
                        Picker("Local reference", selection: Binding(get: { sourceID }, set: { sourceID = $0; configureSource() })) {
                            ForEach(refs) { Text($0.isTag ? String(localized: "Tag · \($0.name)") : String(localized: "Branch · \($0.name)")).tag($0.id) }
                        }
                    }
                    TextField(selectedSource?.isTag == true ? "Remote tag" : "Remote branch", text: $destinationName)
                        .textFieldStyle(.roundedBorder)
                } else {
                    LabeledContent("Destination") {
                        TextField("Remote Reference (refs/heads/… or refs/tags/…)", text: $destinationName).labelsHidden().textFieldStyle(.roundedBorder)
                    }
                }
                if urls.count > 1 {
                    Picker("Push URL", selection: $pushURL) { ForEach(urls, id: \.self) { Text($0).tag($0) } }
                }
                if !deleting && selectedSource?.isLocal == true {
                    LabeledContent("") {
                        Toggle("Set Upstream Tracking", isOn: $tracking).controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }
            }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            if urls.count > 1 {
                Text("Pushes only to the selected URL.").font(.caption).foregroundStyle(.secondary)
            }
            if !deleting {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    Toggle("Force Push with Lease", isOn: $lease).font(.system(size: 12)).controlSize(.small)
                        .foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func configure() {
        sourceID = source?.id ?? refs.first(where: \.isCurrent)?.id ?? refs.first?.id ?? ""
        let trackedRemote = store.managedRemotes.sorted { $0.name.count > $1.name.count }.first { selectedSource?.upstream.hasPrefix($0.name + "/") == true }
        remoteID = remoteName ?? trackedRemote?.name ?? store.managedRemotes.first(where: { $0.name == "origin" })?.name ?? store.managedRemotes.first?.name ?? ""
        lease = force; advanced = force
        configureSource()
        if let destination { destinationName = destination }
    }

    private func configureSource() {
        guard !deleting else { return }
        let upstream = selectedSource?.upstream ?? "", prefix = remoteID + "/"
        destinationName = upstream.hasPrefix(prefix) ? String(upstream.dropFirst(prefix.count)) : selectedSource?.name ?? ""
        tracking = selectedSource?.isLocal == true && upstream.isEmpty
    }

    private func submit() {
        guard !submitDisabled, let remote = selectedRemote, let repo = store.repository else { return }
        if !deleting && !lease, let source = selectedSource {
            store.runRemotePush(remote: remote, source: source, destination: revision, setUpstream: tracking, pushURL: pushURL)
            dismiss()
            return
        }
        // Only destructive operations require a second user decision. Freeze their checked target.
        let source = deleting ? nil : selectedSource, destination = revision, lease = lease, tracking = tracking, url = pushURL
        let token = store.repositoryToken
        checking = true; failure = nil
        confirmationTask = Task {
            defer { checking = false }
            do {
                let checked = try await repo.pushPreview(remote: remote, source: source, destination: destination, forceWithLease: lease, setUpstream: tracking, pushURL: url)
                guard !Task.isCancelled, token == store.repositoryToken, !store.isBusy else { return }
                confirmation = checked
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

private struct PushSheetHeading<Subtitle: View>: View {
    let title: LocalizedStringResource
    let icon: String
    @ViewBuilder var subtitle: Subtitle
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold))
                subtitle.font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
}

struct RemotePushConfirmation: View {
    let preview: RemotePushPreview
    let busy: Bool
    let back: () -> Void
    let push: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PushSheetHeading(title: preview.deletes ? "Delete Remote Reference" : "Force Push with Lease", icon: preview.deletes ? "trash" : "arrow.up") {
                Label(preview.remote.name + "/" + shortDestination, systemImage: "cloud").lineLimit(2)
            }
            Label {
                Text(preview.deletes ? String(localized: "Deletes only this reference on the selected server. Existing local commits and references are retained.") : String(localized: "Replaces the remote reference. Other users may still depend on its current history."))
                    .font(.system(size: 12)).foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Pico.warning)
            }.fixedSize(horizontal: false, vertical: true)
            Label("The operation is rejected if the remote reference changes while you confirm.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Details") {
                Grid(alignment: .leading, verticalSpacing: 8) {
                    GridRow { Text("Push URL"); Text(preview.pushURL).textSelection(.enabled) }
                    GridRow { Text("Destination"); Text(preview.destination).textSelection(.enabled) }
                    GridRow { Text("Server object"); Text(preview.remoteHash.map { String($0.prefix(12)) } ?? String(localized: "Does not exist yet")) }
                    if let source = preview.source {
                        GridRow { Text("New object"); Text(String(source.hash.prefix(12))) }
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            HStack {
                Button("Back", action: back).disabled(busy)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(preview.deletes ? LocalizedStringResource("Delete") : LocalizedStringResource("Force Push"), role: .destructive, action: push)
                    .buttonStyle(.borderedProminent).tint(Pico.deletion).keyboardShortcut(.defaultAction).disabled(busy)
            }
        }.padding(24)
    }
    private var shortDestination: String {
        for prefix in ["refs/heads/", "refs/tags/"] where preview.destination.hasPrefix(prefix) {
            return String(preview.destination.dropFirst(prefix.count))
        }
        return preview.destination
    }
}
