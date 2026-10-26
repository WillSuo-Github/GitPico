import GitCore
import SwiftUI

struct InteractiveRebaseSheet: View {
    var store: RepositoryStore
    let request: RebaseRequest
    @State private var base = ""
    @State private var onto = ""
    @State private var planID = UUID()
    @State private var plan: InteractiveRebasePlan?
    @State private var steps: [RebaseStep] = []
    @State private var selected: String?
    @State private var error: String?
    @State private var loading = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { SheetTitle("Interactive Rebase", icon: "list.bullet.indent"); Spacer(); Text(store.snapshot?.branch ?? "").foregroundStyle(.secondary) }
            HStack {
                Text("Commits after")
                TextField("Base commit or ref", text: $base).textFieldStyle(.roundedBorder).onSubmit { Task { await load() } }
                Menu("Choose…") {
                    ForEach(store.isHistoryDestination ? store.visibleCommits : (store.snapshot?.commits ?? [])) { commit in Button("\(commit.shortHash) · \(commit.subject)") { base = commit.hash; Task { await load() } } }
                }.fixedSize()
                Button("Load Plan") { Task { await load() } }.disabled(loading || base.isEmpty)
            }.font(.system(size: 12))
            if plan != nil {
                HStack { Text("Replay onto"); TextField("Commit or ref", text: $onto).textFieldStyle(.roundedBorder); Text("Oldest first · drag or use arrows to reorder").foregroundStyle(.secondary) }.font(.system(size: 11))
                List(selection: $selected) {
                    ForEach($steps) { $step in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            Text(step.action.rawValue.capitalized).font(.system(size: 11, weight: .medium)).frame(width: 75, alignment: .leading)
                                .foregroundStyle(step.action == .drop ? Color.red : step.action == .pick ? Color.secondary : Color.purple)
                            Text(String(step.hash.prefix(8))).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            Text(step.message.components(separatedBy: "\n").first ?? "").lineLimit(1).strikethrough(step.action == .drop).foregroundStyle(step.action == .drop ? .secondary : .primary)
                            Spacer()
                            Button { move(step.id, by: -1) } label: { Image(systemName: "chevron.up") }.help("Move commit earlier").disabled(steps.first?.id == step.id)
                            Button { move(step.id, by: 1) } label: { Image(systemName: "chevron.down") }.help("Move commit later").disabled(steps.last?.id == step.id)
                        }.font(.system(size: 12)).buttonStyle(.borderless).padding(.vertical, 4).tag(step.id)
                            .picoDrag(store, .rebaseStep(step.id, planID))
                            .picoRebaseDrop(store, planID: planID) { hash, after in
                                guard RebaseStepEditing.move(hash, relativeTo: step.id, after: after, steps: &steps) else { return false }
                                selected = hash; return true
                            }
                            .onChange(of: step.action) { _, action in
                                selected = step.id
                                if action == .squash, let index = steps.firstIndex(where: { $0.id == step.id }), index > 0, step.message == step.originalMessage {
                                    if let previous = steps[..<index].last(where: { $0.action != .drop && $0.action != .fixup }) { step.message = previous.message + "\n\n" + step.originalMessage }
                                }
                            }
                    }
                }.listStyle(.inset).frame(minHeight: 200)
                if let index = steps.firstIndex(where: { $0.id == selected }) {
                    HStack {
                        Picker("Action", selection: $steps[index].action) { ForEach(RebaseAction.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.frame(width: 180)
                        Button { move(steps[index].id, by: -1) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Move Selected Commit Earlier").disabled(index == 0)
                        Button { move(steps[index].id, by: 1) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Move Selected Commit Later").disabled(index == steps.count - 1)
                        Text("Commit message").fontWeight(.medium)
                        Spacer()
                        Text(steps[index].action == .reword || steps[index].action == .squash ? "Used for Reword / Squash" : "Choose Reword to edit the message").foregroundStyle(.secondary)
                    }.font(.system(size: 11))
                    TextEditor(text: $steps[index].message).font(.system(size: 12, design: .monospaced)).frame(height: 100).padding(6).background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                        .disabled(steps[index].action != .reword && steps[index].action != .squash).accessibilityLabel("Rebase commit message")
                }
            } else { EmptyPane(title: loading ? "Loading commits…" : "Choose the starting point", subtitle: "Only commits after this point are rewritten. Linear ranges of up to 200 commits are supported.", icon: "arrow.triangle.branch") }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            if !store.changes.isEmpty { Text(AppPreferences.shared.offerAutomaticStash ? "You will be offered to stash local changes before starting." : "Commit or stash local changes before starting.").foregroundStyle(.orange).font(.callout) }
            HStack {
                Text("Rewrites commit hashes. Original tips are retained for Undo and Reflog recovery.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Rebase") {
                    guard var plan else { return }
                    plan.steps = steps; plan.onto = onto
                    store.startInteractiveRebase(plan); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(plan == nil || loading || (!store.changes.isEmpty && !AppPreferences.shared.offerAutomaticStash) || onto.isEmpty)
            }
        }.padding(24).frame(width: 850, height: 640)
             .task {
                if let value = request.preparedPlan { base = value.base; plan = value; steps = value.steps; onto = value.onto; selected = steps.first?.id }
                else { base = request.base ?? store.selectedCommit?.parents.first ?? "HEAD~1"; await load() }
            }
    }
    func load() async {
        guard let repository = store.repository, !loading else { return }
        loading = true; error = nil; plan = nil; planID = UUID()
        defer { loading = false }
        do { let value = try await repository.rebasePlan(after: base); plan = value; steps = value.steps; onto = value.onto; selected = steps.first?.id }
        catch { self.error = error.localizedDescription }
    }
    func move(_ id: String, by offset: Int) {
        guard let index = steps.firstIndex(where: { $0.id == id }), steps.indices.contains(index + offset) else { return }
        steps.swapAt(index, index + offset); selected = id
    }
}

struct RebaseEditSheet: View {
    var store: RepositoryStore
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle("Amend Paused Commit")
            Text("Includes staged changes. Unstaged files remain in the working copy.").foregroundStyle(.secondary)
            TextEditor(text: $message).font(.system(size: 12, design: .monospaced)).frame(height: 180).accessibilityLabel("Paused commit message")
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Amend Commit") { store.amendRebaseStop(message); dismiss() }.disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 540).onAppear { message = store.rebaseProgress?.currentMessage ?? "" }
    }
}
