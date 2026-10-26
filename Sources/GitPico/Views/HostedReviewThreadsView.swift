import GitCore
import SwiftUI

struct HostedInlineRequest: Identifiable { let id = UUID(); let review: HostedReview; let file: HostedReviewFile; let project: HostedRepository }
private struct HostedReplyRequest: Identifiable { let id = UUID(); let review: HostedReview; let thread: HostedReviewThread; let project: HostedRepository }

struct HostedReviewThreadsView: View {
    @Bindable var model: HostedReviewsModel
    @State private var reply: HostedReplyRequest?
    @State private var resolving: HostedReplyRequest?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let error = model.threadsError { Text(error).foregroundStyle(Pico.warning).textSelection(.enabled) }
                ForEach(model.threads) { thread in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(thread.path + (thread.line.map { ":\($0) · " + thread.side.rawValue } ?? " · outdated line")).font(.caption.bold()).textSelection(.enabled)
                            Spacer()
                            if thread.canResolve { Text(thread.resolved ? "Resolved" : "Unresolved").font(.caption).foregroundStyle(.secondary) }
                        }
                        ForEach(thread.comments) { note in
                            VStack(alignment: .leading, spacing: 4) { Text(note.author).font(.caption.bold()); Text(note.body).textSelection(.enabled) }
                        }
                        HStack {
                            Button("Reply…") { if let review = model.detail, let project = model.client?.repository { reply = HostedReplyRequest(review: review, thread: thread, project: project) } }
                            if thread.canResolve {
                                Button(thread.resolved ? "Reopen Thread…" : "Resolve Thread…") { if let review = model.detail, let project = model.client?.repository { resolving = HostedReplyRequest(review: review, thread: thread, project: project) } }
                            }
                        }.disabled(model.busy)
                    }.padding(10).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                }
                if model.moreThreads { Button("Load More Threads") { Task { await model.loadMoreThreads() } }.disabled(model.busy) }
                if model.threads.isEmpty && model.threadsError == nil { Text("No inline discussions returned. Select a file to start one.").foregroundStyle(.secondary) }
                Text("GitHub thread resolution is available on the hosting website. At most 1,000 server comments/discussions are loaded here.").font(.caption).foregroundStyle(.secondary)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $reply) { request in HostedThreadReplyView(model: model, review: request.review, thread: request.thread, project: request.project) }
        .confirmationDialog("Change this discussion's resolution state?", isPresented: Binding(get: { resolving != nil }, set: { if !$0 { resolving = nil } })) {
            if let request = resolving {
                Button(request.thread.resolved ? "Reopen Thread" : "Resolve Thread") {
                    resolving = nil
                    Task { _ = await model.resolve(review: request.review, thread: request.thread, project: request.project) }
                }
            }
        }
    }
}

struct HostedInlineCommentView: View {
    let model: HostedReviewsModel
    let request: HostedInlineRequest
    @State private var side: HostedDiffSide = .right
    @State private var selected: Int?
    @State private var text = ""
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss
    private var lines: [DiffLine] { DiffDocument(request.file.patch ?? "").lines }
    private var location: Int? { lines.first { $0.id == selected }.flatMap { side == .left ? $0.oldNumber : $0.newNumber } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetTitle("Comment on a Line", icon: "text.bubble")
            Text(request.project.project + " #\(request.review.number) · " + request.file.path).font(.caption).textSelection(.enabled)
            Picker("Side", selection: $side) { Text("Original / Left").tag(HostedDiffSide.left); Text("New / Right").tag(HostedDiffSide.right) }.pickerStyle(.segmented)
            List(lines.filter { (side == .left ? $0.oldNumber : $0.newNumber) != nil }, selection: $selected) { line in
                HStack(alignment: .top, spacing: 10) {
                    Text(String((side == .left ? line.oldNumber : line.newNumber) ?? 0)).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                    Text(line.text).lineLimit(3)
                }.font(.system(.caption, design: .monospaced)).tag(line.id)
            }.frame(height: 250)
            TextEditor(text: $text).frame(height: 100).accessibilityLabel("Inline review comment")
            if let error = model.error { Text(error).foregroundStyle(Pico.deletion).font(.caption).textSelection(.enabled) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Text(location.map { "Line \($0)" } ?? "Select a line").font(.caption); Button("Post Comment…") { confirming = true }.disabled(location == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy) }
        }.padding(24).frame(width: 720)
        .confirmationDialog("Post this comment on the selected line?", isPresented: $confirming) {
            if let line = location { Button("Post Comment") { Task { if await model.postInline(review: request.review, file: request.file, line: line, side: side, text: text, project: request.project) { dismiss() } } } }
        } message: { Text(request.project.project + " #\(request.review.number) · " + request.file.path + ":\(location ?? 0) · " + side.rawValue) }
    }
}

private struct HostedThreadReplyView: View {
    let model: HostedReviewsModel
    let review: HostedReview
    let thread: HostedReviewThread
    let project: HostedRepository
    @State private var text = ""
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetTitle("Reply to Discussion", icon: "text.bubble")
            Text(project.project + " #\(review.number) · " + thread.path).font(.caption)
            TextEditor(text: $text).frame(height: 180).accessibilityLabel("Discussion reply")
            if let error = model.error { Text(error).foregroundStyle(Pico.deletion).textSelection(.enabled) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Post Reply…") { confirming = true }.disabled(model.busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 580)
        .confirmationDialog("Post this reply?", isPresented: $confirming) { Button("Post Reply") { Task { if await model.reply(review: review, thread: thread, text: text, project: project) { dismiss() } } } }
    }
}
