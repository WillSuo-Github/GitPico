import GitCore
import SwiftUI

struct HostedReviewsView: View {
    @State private var model: HostedReviewsModel
    @State private var creating = false
    @Environment(\.dismiss) private var dismiss
    init(store: RepositoryStore) { _model = State(initialValue: HostedReviewsModel(store: store)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SheetTitle(model.provider == .gitlab ? "Merge Requests" : "Pull Requests", icon: "arrow.triangle.pull")
                Spacer()
                Picker("Remote", selection: $model.remote) { ForEach(model.remotes) { Text($0.name).tag($0.name) } }.frame(width: 160).disabled(model.busy)
                Picker("State", selection: $model.state) { Text("Open").tag("open"); Text("Closed").tag("closed"); Text("All").tag("all") }.frame(width: 130).disabled(model.busy)
                Button("Refresh") { Task { await model.reload() } }.disabled(model.busy)
                Button("New…") { creating = true }.disabled(model.client == nil || model.busy)
            }
            if let error = model.error { Text(error).foregroundStyle(Pico.deletion).textSelection(.enabled).font(.callout) }
            if model.busy { ProgressView().controlSize(.small) }
            HSplitView {
                VStack(spacing: 0) {
                    List(model.reviews, selection: $model.selected) { review in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(review.title).fontWeight(.medium).lineLimit(2)
                            Text("#\(review.number) · " + review.author + " · " + review.state).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(review.number)
                    }.listStyle(.plain)
                    if model.more { Button("Load More") { Task { await model.reload(append: true) } }.padding(8).disabled(model.busy) }
                }.frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                HostedReviewDetailView(model: model).frame(minWidth: 500)
            }.frame(minHeight: 510)
            HStack {
                Text("Uses this repository's selected HTTPS account. Server permissions and branch protections remain in effect.").font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 1040)
        .task { await model.reload() }
        .onChange(of: model.state) { Task { await model.reload() } }
        .onChange(of: model.remote) { if model.client != nil { Task { await model.reload() } } }
        .task(id: model.selected) { await model.loadDetail() }
        .sheet(isPresented: $creating) { HostedReviewCreateView(model: model) }
    }
}

struct HostedReviewCreateView: View {
    let model: HostedReviewsModel
    @State private var title = ""
    @State private var bodyText = ""
    @State private var source = ""
    @State private var target = "main"
    @State private var draft = true
    @State private var sourceProject = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle("Create Review", icon: "arrow.triangle.pull")
            TextField("Title", text: $title)
            HStack { TextField("Published source branch", text: $source); Text("→"); TextField("Target branch", text: $target) }
            TextField("Source fork project (optional, owner/repository)", text: $sourceProject)
            Text("Target project: " + (model.client?.repository.project ?? "")).font(.caption).textSelection(.enabled)
            Text("Push the source branch before creating the review. This action creates a review on the selected remote; it does not push commits.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $bodyText).font(.body).frame(height: 160).border(.separator)
            Toggle("Create as draft", isOn: $draft)
            if let error = model.error { Text(error).foregroundStyle(Pico.deletion).font(.caption) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Create") { Task { if await model.create(title: title, body: bodyText, source: source, target: target, draft: draft, sourceProject: sourceProject) { dismiss() } } }.disabled(model.busy || title.isEmpty || source.isEmpty || target.isEmpty || (source == target && sourceProject.isEmpty)) }
        }.padding(24).frame(width: 600).onAppear { source = model.store.snapshot?.branch ?? "" }
    }
}
