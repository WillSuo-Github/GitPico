import Foundation

public enum HostedDiffSide: String, CaseIterable, Sendable { case left = "LEFT", right = "RIGHT" }
public struct HostedReviewThread: Identifiable, Sendable {
    public let id: String
    public var comments: [HostedReviewComment]
    public let path: String
    public let line: Int?
    public let side: HostedDiffSide
    public let resolved: Bool
    public let canResolve: Bool
}
public struct HostedThreadPage: Sendable { public let items: [HostedReviewThread]; public let hasMore: Bool }
extension HostedReviewClient {
    public func threadPage(_ review: HostedReview, page: Int = 1) async throws -> HostedThreadPage {
        let github = repository.provider == .github
        let items = try array(await send(path: reviews + "/\(review.number)/" + (github ? "comments" : "discussions"), query: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(max(1, page)))]))
        if github {
            var grouped: [HostedReviewThread] = []
            for item in items {
                guard let id = item["id"] as? Int else { continue }
                let root = String(item["in_reply_to_id"] as? Int ?? id)
                let note = HostedReviewComment(id: id, author: (item["user"] as? [String: Any])?["login"] as? String ?? "Unknown", body: item["body"] as? String ?? "")
                if let index = grouped.firstIndex(where: { $0.id == root }) { grouped[index].comments.append(note) }
                else { grouped.append(HostedReviewThread(id: root, comments: [note], path: item["path"] as? String ?? "", line: item["line"] as? Int, side: HostedDiffSide(rawValue: item["side"] as? String ?? "RIGHT") ?? .right, resolved: false, canResolve: false)) }
            }
            return HostedThreadPage(items: grouped, hasMore: items.count == 100)
        }
        let threads = items.compactMap { item -> HostedReviewThread? in
            guard let id = item["id"] as? String, let notes = item["notes"] as? [[String: Any]], let first = notes.first, let position = first["position"] as? [String: Any] else { return nil }
            let comments = notes.compactMap { note -> HostedReviewComment? in
                guard let noteID = note["id"] as? Int else { return nil }
                return HostedReviewComment(id: noteID, author: (note["author"] as? [String: Any])?["username"] as? String ?? "Unknown", body: note["body"] as? String ?? "")
            }
            return HostedReviewThread(id: id, comments: comments, path: position["new_path"] as? String ?? position["old_path"] as? String ?? "", line: position["new_line"] as? Int ?? position["old_line"] as? Int, side: position["new_line"] is Int ? .right : .left, resolved: first["resolved"] as? Bool ?? false, canResolve: first["resolvable"] as? Bool ?? false)
        }
        return HostedThreadPage(items: threads, hasMore: items.count == 100)
    }

    public func commentInline(_ review: HostedReview, file: HostedReviewFile, line: Int, side: HostedDiffSide, text: String) async throws {
        try validateReviewText(text)
        let current = try await detail(review.number)
        guard current.head == review.head, !review.head.isEmpty, current.diffBase == review.diffBase, current.diffStart == review.diffStart else { throw GitFailure("The review's head or comparison base changed. Reload before commenting on a line.") }
        var matched: HostedReviewFile?
        for page in 1...10 {
            let batch = try await files(review.number, page: page)
            matched = batch.first { $0.path == file.path }
            if matched != nil || batch.count < 100 { break }
        }
        guard let matched, let patch = matched.patch, patch == file.patch, matched.previousPath == file.previousPath,
              let selected = DiffDocument(patch).lines.first(where: { (side == .left ? $0.oldNumber : $0.newNumber) == line }), line > 0 else { throw GitFailure("This line is not present in the reviewed server diff. Reload the files before commenting.") }
        var fields: [String: HostedJSON] = ["body": .text(text)]
        if repository.provider == .github {
            fields["commit_id"] = .text(review.head); fields["path"] = .text(file.path); fields["line"] = .number(line); fields["side"] = .text(side.rawValue)
        } else {
            guard !review.diffBase.isEmpty, !review.diffStart.isEmpty else { throw GitFailure("GitLab has not prepared the diff references yet. Refresh the review before commenting.") }
            var position: [String: HostedJSON] = ["position_type": .text("text"), "base_sha": .text(review.diffBase), "start_sha": .text(review.diffStart), "head_sha": .text(review.head), "old_path": .text(file.previousPath ?? file.path), "new_path": .text(file.path)]
            if let old = selected.oldNumber { position["old_line"] = .number(old) }
            if let new = selected.newNumber { position["new_line"] = .number(new) }
            fields["position"] = .object(position)
        }
        _ = try await send("POST", path: reviews + "/\(review.number)/" + (repository.provider == .github ? "comments" : "discussions"), body: fields)
    }

    public func reply(_ review: HostedReview, thread: HostedReviewThread, text: String) async throws {
        try validateReviewText(text)
        guard !thread.id.isEmpty, thread.id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { throw GitFailure("Invalid review thread identifier.") }
        let github = repository.provider == .github
        _ = try await send("POST", path: reviews + "/\(review.number)/" + (github ? "comments/\(HostedRepository.component(thread.id))/replies" : "discussions/\(HostedRepository.component(thread.id))/notes"), body: ["body": .text(text)])
    }
    public func resolve(_ review: HostedReview, thread: HostedReviewThread, resolved: Bool) async throws {
        guard repository.provider == .gitlab, thread.canResolve else { throw GitFailure("This thread's resolve state must be managed on the hosting website.") }
        _ = try await send("PUT", path: reviews + "/\(review.number)/discussions/" + HostedRepository.component(thread.id), body: ["resolved": .flag(resolved)])
    }
    private func validateReviewText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 100_000 else { throw GitFailure("Enter a comment up to 100 KB.") }
    }
}
