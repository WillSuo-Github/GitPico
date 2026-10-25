import GitCore
import SwiftUI

struct GitFlowToolbarMenu: View {
    let store: RepositoryStore
    var body: some View {
        Menu {
            Button("Git Flow Settings…", action: store.showGitFlow)
            Button(store.flowConfiguration == nil ? "Enable Git Flow…" : "Configure Git Flow…") { store.manageFlow(.configure) }.disabled(store.activeFlow != nil)
            if store.flowConfiguration != nil {
                Divider()
                ForEach(GitFlowKind.allCases, id: \.self) { kind in Button("Start " + kind.rawValue + "…") { store.manageFlow(.start(kind)) } }.disabled(store.activeFlow != nil)
                if let current = store.snapshot?.references.first(where: \.isCurrent), let kind = store.flowConfiguration?.kind(of: current.name), kind != .support {
                    Button("Finish " + kind.rawValue + "…") { store.manageFlow(.finish(current.name)) }.disabled(store.activeFlow != nil)
                }
            }
            if let active = store.activeFlow {
                Divider()
                Button("Continue Git Flow…") { store.manageFlow(.resume(active)) }
                Button("Stop Git Flow…") { store.manageFlow(.stop(active)) }
            }
        } label: { Label("Git Flow", systemImage: "arrow.triangle.branch") }.disabled(store.repository == nil || store.isBusy)
    }
}
struct GitFlowSettingsPane: View {
    @Bindable var store: RepositoryStore
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack { Label("Git Flow", systemImage: "arrow.triangle.branch").font(.title2.bold()); Spacer(); GitFlowToolbarMenu(store: store); Button("Reload") { Task { await store.loadWorkflowState() } }.disabled(store.isBusy) }
                Text("Classic Git Flow implemented with Git. Compatible repository-local gitflow.* branch/prefix settings; no separate git-flow script is required. Custom CLI hooks and alternative workflow engines are not executed.").font(.callout).foregroundStyle(.secondary)
                if let config = store.flowConfiguration {
                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 9) {
                        GridRow { Text("Production").foregroundStyle(.secondary); Text(config.production) }
                        GridRow { Text("Development").foregroundStyle(.secondary); Text(config.development) }
                        ForEach(GitFlowKind.allCases, id: \.self) { kind in GridRow { Text(kind.rawValue).foregroundStyle(.secondary); Text(config.prefix(kind)).monospaced() } }
                        GridRow { Text("Version tags").foregroundStyle(.secondary); Text(config.versionTag.isEmpty ? "No prefix" : config.versionTag) }
                    }
                    Divider()
                    Text("TOPIC BRANCHES").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach((store.snapshot?.references ?? []).filter { $0.isLocal && config.kind(of: $0.name) != nil }) { ref in
                        HStack {
                            Image(systemName: "arrow.triangle.branch")
                            VStack(alignment: .leading, spacing: 4) { Text(ref.name).font(.system(size: 12, weight: .medium)); Text(String(ref.hash.prefix(8)) + (ref.isCurrent ? " · HEAD" : "")).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            Spacer()
                            if config.kind(of: ref.name) != .support { Button("Finish…") { store.manageFlow(.finish(ref.name)) }.disabled(store.activeFlow != nil) }
                            Button("Publish…") { store.manage(.publish(ref, nil, nil, false)) }.disabled(store.managedRemotes.isEmpty)
                            Button("History") { store.navigate(.reference(ref.fullName)) }
                        }.disabled(store.isBusy).padding(.vertical, 4)
                    }
                    Text("Start may track a chosen remote branch. Finish merges feature → development, or release/hotfix → production + annotated version tag → development. The topic is removed only after all steps succeed, unless Keep Branch is selected. Push remains a separate reviewed action.").font(.caption).foregroundStyle(.secondary)
                } else { ContentUnavailableView("Git Flow is not enabled", systemImage: "arrow.triangle.branch", description: Text("Choose production/development branches and topic prefixes to begin.")); Button("Enable Git Flow…") { store.manageFlow(.configure) }.disabled(store.isBusy) }
                if let active = store.activeFlow { flowRecord(active); HStack { Button("Continue…") { store.manageFlow(.resume(active)) }; Button("Resolve in Working Copy") { store.navigate(.workingCopy) }; Button("Stop…") { store.manageFlow(.stop(active)) } }.disabled(store.isBusy) }
                if let error = store.workflowError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                DisclosureGroup("Flow History") { ForEach(store.flowHistory.prefix(50)) { record in flowRecord(record) } }
            }.padding(22).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.task(id: store.repositoryToken) { await store.loadWorkflowState() }
    }
    func flowRecord(_ record: GitFlowRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(record.title).fontWeight(.medium); Spacer(); Text(record.state).foregroundStyle(.secondary) }
            Text(record.date.formatted() + " · \(record.next)/\(record.stepCount) steps").font(.caption).foregroundStyle(.secondary)
            if let diagnostic = record.diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(.vertical, 8)
    }
}
struct GitFlowOperationBanner: View {
    let store: RepositoryStore
    var body: some View {
        if let active = store.activeFlow {
            HStack {
                Label(active.title + " · \(active.next)/\(active.stepCount)", systemImage: "arrow.triangle.branch").font(.caption)
                Spacer(); Button("Git Flow…", action: store.showGitFlow)
                Button("Continue…") { store.manageFlow(.resume(active)) }.disabled(store.isBusy)
            }.padding(.horizontal, 14).padding(.vertical, 7).background(.bar)
        }
    }
}
