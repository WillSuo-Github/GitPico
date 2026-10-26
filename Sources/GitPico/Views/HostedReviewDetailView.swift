import GitCore
import SwiftUI

private struct HostedReviewConfirmation: Identifiable {
    let id = UUID()
    let action: HostedReviewAction
    let review: HostedReview
    let text: String
    let repository: HostedRepository
}
struct HostedReviewDetailView: View {
    @Bindable var model: HostedReviewsModel
    @State private var tab = "Overview"
    @State private var selectedFile: String?
    @State private var comment = ""
    @State private var confirmation: HostedReviewConfirmation?
    @State private var inline: HostedInlineRequest?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let review = model.detail {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(review.title).font(.headline).textSelection(.enabled)
                        Text(review.source + " → " + review.target + " · " + review.state).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(); Link("Open on Web", destination: review.url)
                }
                Picker("Review detail", selection: $tab) { ForEach(["Overview", "Files", "Discussions", "Checks"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                if tab == "Files" {
                    HSplitView {
                        VStack {
                            List(model.files, selection: $selectedFile) { file in Text(file.path).font(.caption).tag(file.path) }.frame(minWidth: 130, maxWidth: 230)
                            if model.moreFiles { Button("Load More Files") { Task { await model.loadMoreFiles() } } }
                        }
                        if let file = model.files.first(where: { $0.path == selectedFile }) {
                            VStack {
                                HStack { Text(file.path).font(.caption).lineLimit(1); Spacer(); Button("Comment on Line…") { if let project = model.client?.repository { inline = HostedInlineRequest(review: review, file: file, project: project) } }.disabled(file.patch == nil || model.busy) }
                                DiffView(text: file.patch ?? "The server did not return a text patch. Open the review on the web for binary, oversized or truncated differences.", title: file.path)
                            }
                        } else { Text("Select a file").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                } else if tab == "Discussions" {
                    HostedReviewThreadsView(model: model)
                } else if tab == "Checks" {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if let error = model.checksError { Text(error).foregroundStyle(Pico.warning) }
                            ForEach(model.checks) { check in HStack { Text(check.name); Spacer(); Text(check.status).foregroundStyle(.secondary) } }
                            if model.checks.isEmpty && model.checksError == nil { Text("No checks returned by the server.").foregroundStyle(.secondary) }
                            Text("Server checks may still be running. Refresh before merging; the server enforces its protection rules.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(review.body.isEmpty ? "No description." : review.body).textSelection(.enabled)
                            Divider()
                            ForEach(model.comments) { comment in
                                VStack(alignment: .leading, spacing: 4) { Text(comment.author).font(.caption.bold()); Text(comment.body).textSelection(.enabled) }
                            }
                            if model.moreComments { Button("Load More Comments") { Task { await model.loadMoreComments() } } }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                Divider()
                TextEditor(text: $comment).font(.body).frame(height: 70).border(.separator).accessibilityLabel("Review comment")
                HStack {
                    Button("Comment…") { prepare(.comment, review) }.disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Approve…") { prepare(.approve, review) }.disabled(!["open", "opened"].contains(review.state))
                    if model.provider == .github { Button("Request Changes…") { prepare(.requestChanges, review) }.disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !["open", "opened"].contains(review.state)) }
                    Spacer()
                    Menu("State…") {
                        Button("Close Review…") { prepare(.close, review) }.disabled(!["open", "opened"].contains(review.state))
                        Button("Reopen Review…") { prepare(.reopen, review) }.disabled(review.state != "closed")
                    }
                    Menu("Merge…") { Button("Merge Commit…") { prepare(.merge, review) }; Button("Squash and Merge…") { prepare(.squash, review) } }.disabled(!["open", "opened"].contains(review.state))
                }.disabled(model.busy)
            } else { ContentUnavailableView("Select a Review", systemImage: "arrow.triangle.pull") }
        }.padding(12)
        .sheet(item: $inline) { HostedInlineCommentView(model: model, request: $0) }
        .onChange(of: model.selected) { selectedFile = nil; comment = "" }
        .confirmationDialog(confirmation?.action.rawValue ?? "Review Action", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            if let captured = confirmation {
                Button(captured.action.rawValue) {
                    confirmation = nil
                    Task { if await model.execute(captured.action, review: captured.review, text: captured.text, repository: captured.repository) { comment = "" } }
                }
            }
        } message: {
            if let captured = confirmation { Text("Apply “\(captured.action.rawValue)” to #\(captured.review.number) “\(captured.review.title)” on the selected remote? Merge uses the reviewed head commit; reload if it changed.") }
        }
    }
    private func prepare(_ action: HostedReviewAction, _ review: HostedReview) {
        guard let repository = model.client?.repository else { return }
        confirmation = HostedReviewConfirmation(action: action, review: review, text: comment, repository: repository)
    }
}
