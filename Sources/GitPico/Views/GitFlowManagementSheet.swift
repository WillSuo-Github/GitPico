import GitCore
import SwiftUI

struct GitFlowManagementSheet: View {
    let store: RepositoryStore
    let request: FlowRequest
    @Environment(\.dismiss) private var dismiss
    @State private var config = GitFlowConfiguration()
    @State private var name = ""
    @State private var revision = ""
    @State private var track = false
    @State private var remoteRef = ""
    @State private var keep = false
    @State private var sign = false
    @State private var message = ""
    @State private var plan: GitFlowPlan?
    @State private var reviewedRecord = false
    @State private var loading = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle("Git Flow", icon: "arrow.triangle.branch")
            if let plan {
                Text(plan.action == .configure ? String(localized: "Configure Classic Git Flow") : plan.action == .finish ? "\(plan.kind.finishTitle) · \(plan.name)" : "\(plan.kind.startTitle) · \(plan.name)").font(.headline)
                ForEach(plan.targets, id: \.self) { Text($0).font(.system(size: 13, design: .monospaced)) }
                if let tag = plan.tag { Text("Annotated version tag: \(tag)").fontWeight(.medium) }
                Text(plan.action == .configure ? String(localized: "Creates development from production only if missing. Saves repository-local branch/prefix configuration, without changing global settings or checking out a different branch.") : plan.action == .finish ? String(localized: "Merges the reviewed topic into the listed bases. Conflicts pause the flow for resolution in Working Copy. Completed merges/tags are retained when stopping.") + " " + (plan.keepBranch ? String(localized: "The topic branch is kept.") : String(localized: "The topic branch is deleted only after successful completion.")) : String(localized: "Creates and checks out the topic from an immutable commit. Existing file changes and branches are protected.")).foregroundStyle(.secondary)
                Text("No remote push or deletion runs as part of this action.").font(.caption).foregroundStyle(.secondary)
            } else {
                switch request.action {
                case .configure:
                    TextField("Production branch", text: $config.production)
                    TextField("Development branch", text: $config.development)
                    TextField("Feature prefix", text: $config.feature)
                    TextField("Release prefix", text: $config.release)
                    TextField("Hotfix prefix", text: $config.hotfix)
                    TextField("Support prefix", text: $config.support)
                    TextField("Version tag prefix (optional)", text: $config.versionTag)
                case .start(let kind):
                    Text(kind.startTitle).font(.headline)
                    TextField("Topic name", text: $name)
                    Toggle("Track an existing remote branch", isOn: $track).toggleStyle(.checkbox)
                    if track { Picker("Remote branch", selection: $remoteRef) { ForEach((store.snapshot?.references ?? []).filter(\.isRemote)) { ref in Text(ref.name).tag(ref.fullName) } } }
                    else { TextField("Start revision (optional; uses the configured base)", text: $revision) }
                case .finish(let branch):
                    Text("Finish \(branch)").font(.headline)
                    Toggle("Keep topic branch", isOn: $keep).toggleStyle(.checkbox)
                    if store.flowConfiguration?.kind(of: branch) != .feature {
                        TextField("Annotated tag message", text: $message)
                        Toggle("Sign version tag with the existing repository signing setup", isOn: $sign).toggleStyle(.checkbox)
                    }
                case .resume(let record), .stop(let record):
                    Text(record.title).font(.headline)
                    Text("\(record.next) of \(record.stepCount) steps completed · \(record.repository)").font(.caption).foregroundStyle(.secondary)
                    if let diagnostic = record.diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    if case .stop = request.action { Text("Aborts only the active Git Flow merge, then stops the remaining steps. Earlier completed merges/tags and the topic branch are retained; no shared history is reset.").foregroundStyle(.secondary) }
                    else { Text("Resolve and stage current conflicts before continuing. An already completed manual merge is verified before the remaining steps run.").foregroundStyle(.secondary) }
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if loading { ProgressView().controlSize(.small) }; Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if plan != nil || reviewedRecord {
                    Button("Back") { plan = nil; reviewedRecord = false }
                    Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
                } else { Button("Review…") { Task { await review() } }.keyboardShortcut(.defaultAction) }
            }.disabled(loading || store.isBusy)
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 660).task {
            config = store.flowConfiguration ?? GitFlowConfiguration(production: store.snapshot?.references.contains(where: { $0.fullName == "refs/heads/main" }) == true ? "main" : store.snapshot?.references.contains(where: { $0.fullName == "refs/heads/master" }) == true ? "master" : store.snapshot?.branch ?? "main")
            remoteRef = store.snapshot?.references.first(where: \.isRemote)?.fullName ?? ""
        }
    }
    func review() async {
        guard let repository = store.repository, request.token == store.repositoryToken else { failure = String(localized: "The repository changed. Reopen Git Flow."); return }
        loading = true; failure = nil; defer { loading = false }
        do {
            switch request.action {
            case .configure: plan = try await repository.previewGitFlowConfiguration(config)
            case .start(let kind): plan = try await repository.previewGitFlowStart(kind, name: name, revision: revision, tracking: track ? remoteRef : nil)
            case .finish(let branch): plan = try await repository.previewGitFlowFinish(branch: branch, keepBranch: keep, tagMessage: message, signTag: sign)
            case .resume, .stop: reviewedRecord = true
            }
        } catch { failure = error.localizedDescription }
    }
    func apply() {
        if let plan { store.applyFlow(plan, request: request) }
        else { switch request.action { case .resume(let record): store.continueFlow(record, stop: false, request: request); case .stop(let record): store.continueFlow(record, stop: true, request: request); default: break } }
        dismiss()
    }
}
