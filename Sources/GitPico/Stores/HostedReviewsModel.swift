import Foundation
import GitCore
import Observation

enum HostedReviewAction: String, Identifiable {
    case comment = "Post Comment", approve = "Approve", requestChanges = "Request Changes", merge = "Merge", squash = "Squash and Merge", close = "Close Review", reopen = "Reopen Review"
    var id: String { rawValue }
}
@MainActor @Observable final class HostedReviewsModel {
    let store: RepositoryStore
    private let root: URL?
    var remote = ""
    var state = "open"
    var remotes: [RemoteConfiguration] = []
    var reviews: [HostedReview] = []
    var selected: Int?
    var detail: HostedReview?
    var files: [HostedReviewFile] = []
    var checks: [HostedReviewCheck] = []
    var comments: [HostedReviewComment] = []
    var threads: [HostedReviewThread] = []
    var threadsError: String?
    var threadPage = 1
    var moreThreads = false
    var checksError: String?
    var error: String?
    var busy = false
    var page = 1
    var filePage = 1
    var commentPage = 1
    var more = false
    var moreFiles = false
    var moreComments = false
    private(set) var client: HostedReviewClient?
    @ObservationIgnored private var generation = UUID()
    init(store: RepositoryStore) { self.store = store; root = store.snapshot?.root }
    var provider: OAuthProvider? { client?.repository.provider }
    private func validateRoot() throws {
        guard root != nil, store.snapshot?.root == root else { throw GitFailure("The repository changed. Reopen hosted reviews for the current repository.") }
    }
    private func connect() async throws -> HostedReviewClient {
        try validateRoot()
        guard let repository = store.repository, let root else { throw GitFailure("Open a repository first.") }
        remotes = try await repository.remoteConfigurations()
        if remote.isEmpty { remote = remotes.first(where: { $0.name == "origin" })?.name ?? remotes.first?.name ?? "" }
        guard let item = remotes.first(where: { $0.name == remote }), let profile = store.authentication.profile(for: root), profile.provider != .generic else {
            throw GitFailure("Select a GitHub or GitLab HTTPS account for this repository in Authentication, then choose its remote.")
        }
        let credential = profile.isOAuth ? try await OAuthCredentialRefresher.shared.credential(profile.id) : try store.authentication.vault.read(profile.id)
        let project = try HostedRepository(remote: item.fetchURL, provider: profile.provider == .github ? .github : .gitlab)
        return try HostedReviewClient(repository: project, credential: credential)
    }
    func reload(append: Bool = false) async {
        guard !busy else { return }
        let previous = selected
        if !append {
            generation = UUID(); client = nil; detail = nil
            files = []; checks = []; comments = []; reviews = []; threads = []; moreThreads = false; threadsError = nil
            more = false; moreFiles = false; moreComments = false
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            let client = try await connect()
            let next = append ? page + 1 : 1
            guard next <= 20 else { throw GitFailure("600 reviews are loaded. Narrow the state filter or continue on the hosting website.") }
            let items = try await client.list(state: state, page: next)
            try Task.checkCancellation(); try validateRoot()
            self.client = client
            if append { let known = Set(reviews.map(\.id)); reviews += items.filter { !known.contains($0.id) } }
            else { reviews = items }
            page = next; more = items.count == 30
            if !append {
                selected = items.contains(where: { $0.number == previous }) ? previous : items.first?.number
                if previous == selected { await loadDetail() }
            }
        } catch is CancellationError { }
        catch { self.error = GitLogRedaction.clean(error.localizedDescription) }
    }
    func loadDetail() async {
        let token = UUID(); generation = token
        detail = nil; files = []; checks = []; comments = []; threads = []; moreThreads = false; threadsError = nil; checksError = nil; error = nil
        guard let number = selected, let client else { return }
        do {
            let review = try await client.detail(number)
            async let fetchedFiles = client.files(number)
            async let fetchedComments = client.comments(number)
            let (files, comments) = try await (fetchedFiles, fetchedComments)
            try Task.checkCancellation(); guard token == generation else { return }
            self.detail = review; self.files = files; self.comments = comments
            filePage = 1; commentPage = 1; moreFiles = files.count == 100; moreComments = comments.count == 100
            do {
                let page = try await client.threadPage(review)
                try Task.checkCancellation(); if token == generation { threads = page.items; moreThreads = page.hasMore; threadPage = 1 }
            } catch { if token == generation && !Task.isCancelled { threadsError = GitLogRedaction.clean(error.localizedDescription) } }
            do { let checks = try await client.checks(review); try Task.checkCancellation(); if token == generation { self.checks = checks } }
            catch { if token == generation && !Task.isCancelled { checksError = GitLogRedaction.clean(error.localizedDescription) } }
            do { let statuses = try await client.legacyChecks(review); try Task.checkCancellation(); if token == generation { self.checks += statuses } }
            catch { if token == generation && !Task.isCancelled { checksError = [checksError, GitLogRedaction.clean(error.localizedDescription)].compactMap { $0 }.joined(separator: "\n") } }
        } catch is CancellationError { }
        catch { if token == generation { self.error = GitLogRedaction.clean(error.localizedDescription) } }
    }
    func loadMoreFiles() async {
        guard !busy, let detail, let client, filePage < 10 else { return }
        busy = true; defer { busy = false }
        do {
            let items = try await client.files(detail.number, page: filePage + 1)
            guard self.detail?.number == detail.number else { return }
            let known = Set(files.map(\.id)); files += items.filter { !known.contains($0.id) }
            filePage += 1; moreFiles = items.count == 100 && filePage < 10
        } catch { self.error = GitLogRedaction.clean(error.localizedDescription) }
    }
    func loadMoreComments() async {
        guard !busy, let detail, let client, commentPage < 10 else { return }
        busy = true; defer { busy = false }
        do {
            let items = try await client.comments(detail.number, page: commentPage + 1)
            guard self.detail?.number == detail.number else { return }
            let known = Set(comments.map(\.id)); comments += items.filter { !known.contains($0.id) }
            commentPage += 1; moreComments = items.count == 100 && commentPage < 10
        } catch { self.error = GitLogRedaction.clean(error.localizedDescription) }
    }
    func create(title: String, body: String, source: String, target: String, draft: Bool, sourceProject: String = "") async -> Bool {
        guard !busy, let client else { return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            try validateRoot()
            let result = try await client.create(title: title, body: body, source: source, target: target, draft: draft, sourceProject: sourceProject.isEmpty ? nil : sourceProject)
            reviews.insert(result, at: 0); selected = result.number
            return true
        } catch { self.error = GitLogRedaction.clean(error.localizedDescription); return false }
    }
    func loadMoreThreads() async {
        guard !busy, let detail, let client, threadPage < 10 else { return }
        let token = generation
        busy = true; defer { busy = false }
        do {
            let page = try await client.threadPage(detail, page: threadPage + 1)
            guard generation == token else { return }
            for item in page.items {
                if let index = threads.firstIndex(where: { $0.id == item.id }) {
                    let known = Set(threads[index].comments.map(\.id)); threads[index].comments += item.comments.filter { !known.contains($0.id) }
                } else { threads.append(item) }
            }
            threadPage += 1; moreThreads = page.hasMore && threadPage < 10
        } catch { threadsError = GitLogRedaction.clean(error.localizedDescription) }
    }
    func postInline(review: HostedReview, file: HostedReviewFile, line: Int, side: HostedDiffSide, text: String, project: HostedRepository) async -> Bool {
        await threadAction(review: review, project: project) { try await $0.commentInline(review, file: file, line: line, side: side, text: text) }
    }
    func reply(review: HostedReview, thread: HostedReviewThread, text: String, project: HostedRepository) async -> Bool {
        await threadAction(review: review, project: project) { try await $0.reply(review, thread: thread, text: text) }
    }
    func resolve(review: HostedReview, thread: HostedReviewThread, project: HostedRepository) async -> Bool {
        await threadAction(review: review, project: project) { try await $0.resolve(review, thread: thread, resolved: !thread.resolved) }
    }
    private func threadAction(review: HostedReview, project: HostedRepository, action: (HostedReviewClient) async throws -> Void) async -> Bool {
        guard !busy, let client else { return false }
        busy = true; error = nil
        do {
            try validateRoot()
            guard client.repository == project, detail?.number == review.number, detail?.head == review.head else { throw GitFailure("The selected review changed. Reopen this action.") }
            try await action(client)
            busy = false; await loadDetail(); return true
        } catch { busy = false; self.error = GitLogRedaction.clean(error.localizedDescription); return false }
    }
    func execute(_ action: HostedReviewAction, review: HostedReview, text: String, repository: HostedRepository) async -> Bool {
        guard !busy, let client else { return false }
        busy = true; error = nil
        do {
            try validateRoot()
            guard client.repository == repository else { throw GitFailure("The selected hosting project changed. Review this action again.") }
            switch action {
            case .comment: try await client.comment(review, text: text)
            case .approve: try await client.approve(review, comment: text)
            case .requestChanges: try await client.approve(review, comment: text, requestChanges: true)
            case .merge, .squash: try await client.merge(review, squash: action == .squash)
            case .close, .reopen: try await client.setClosed(review, closed: action == .close)
            }
            busy = false
            await reload(); selected = review.number; await loadDetail()
            return true
        } catch { busy = false; self.error = GitLogRedaction.clean(error.localizedDescription); return false }
    }
}
