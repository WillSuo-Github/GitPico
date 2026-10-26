import Foundation

public struct HostedRepository: Sendable, Equatable {
    public let provider: OAuthProvider
    public let host: String
    public let project: String
    public init(remote: String, provider: OAuthProvider) throws {
        let host: String, path: String
        if let url = URLComponents(string: remote), ["https", "ssh"].contains(url.scheme), let hostname = url.host {
            guard url.password == nil else { throw GitFailure("Remove embedded passwords from the remote URL before using hosted reviews.") }
            host = hostname.lowercased() + (url.scheme == "https" ? url.port.map { ":\($0)" } ?? "" : "")
            path = url.path
        } else if let colon = remote.firstIndex(of: ":"), !remote.contains("://") {
            host = String(remote[..<colon].split(separator: "@").last ?? "").lowercased()
            path = String(remote[remote.index(after: colon)...])
        } else { throw GitFailure("Select a GitHub or GitLab HTTPS/SSH remote.") }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let project = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed
        let parts = project.split(separator: "/", omittingEmptySubsequences: false)
        guard let address = URLComponents(string: "https://" + host), address.host?.isEmpty == false,
              address.user == nil, address.password == nil, address.path.isEmpty, address.query == nil, address.fragment == nil,
              !host.contains(where: { $0.isWhitespace || $0 == "\\" || $0 == "\0" }),
              parts.count >= 2, provider != .github || parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(where: { $0.isWhitespace || $0 == "\\" || $0 == "\0" }) }) else { throw GitFailure("The remote does not identify a supported hosted project.") }
        self.provider = provider; self.host = host; self.project = project
    }
    public var webURL: URL { URL(string: "https://" + host + "/" + project.split(separator: "/").map { Self.component(String($0)) }.joined(separator: "/"))! }
    var apiBase: String { provider == .github ? (["github.com", "github.com:443"].contains(host) ? "https://api.github.com" : "https://" + host + "/api/v3") : "https://" + host + "/api/v4" }
    var route: String { provider == .github ? "/repos/" + project.split(separator: "/").map { Self.component(String($0)) }.joined(separator: "/") : "/projects/" + Self.component(project) }
    static func component(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))! }
}
public struct HostedReview: Identifiable, Sendable, Equatable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let body: String
    public let author: String
    public let source: String
    public let target: String
    public let head: String
    public let state: String
    public let url: URL
    public var diffBase: String = ""
    public var diffStart: String = ""
}
public struct HostedReviewFile: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let previousPath: String?
    public let status: String
    public let patch: String?
}
public struct HostedReviewCheck: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let status: String
}
public struct HostedReviewComment: Identifiable, Sendable {
    public let id: Int
    public let author: String
    public let body: String
}
public enum HostedJSON: Encodable, Sendable {
    case text(String), flag(Bool), number(Int)
    indirect case object([String: HostedJSON])
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self { case .text(let value): try container.encode(value); case .flag(let value): try container.encode(value); case .number(let value): try container.encode(value); case .object(let value): try container.encode(value) }
    }
}

public struct HostedReviewClient: Sendable {
    public let repository: HostedRepository
    private let credential: GitStoredCredential
    private let transport: any OAuthHTTPTransport
    public init(repository: HostedRepository, credential: GitStoredCredential, transport: any OAuthHTTPTransport = OAuthHTTPSClient(maximumResponseBytes: 4 * 1024 * 1024)) throws {
        guard credential.host == repository.host else { throw GitFailure("Choose an HTTPS account matching this remote's exact host.") }
        if repository.provider == .gitlab, let oauth = credential.oauth, !oauth.scopes.contains("api"), !oauth.scopes.contains("read_api") {
            throw GitFailure("Merge Requests require GitLab API permissions. In Authentication, enable Merge Requests API access or connect an API-authorized token.")
        }
        self.repository = repository; self.credential = credential; self.transport = transport
    }
    var reviews: String { repository.route + (repository.provider == .github ? "/pulls" : "/merge_requests") }
    func send(_ method: String = "GET", path: String, query: [URLQueryItem] = [], body: [String: HostedJSON]? = nil) async throws -> Data {
        try Task.checkCancellation()
        var components = URLComponents(string: repository.apiBase + path)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw GitFailure("The hosting API address is invalid.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GitPico", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if repository.provider == .gitlab && credential.oauth == nil { request.setValue(credential.secret, forHTTPHeaderField: "PRIVATE-TOKEN") }
        else { request.setValue("Bearer " + credential.secret, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else {
            let advice = response.status == 401 ? "Sign in again; this authorization may have expired or been revoked." : response.status == 403 ? "Check API permissions, organization/SSO policy and branch protection." : response.status == 429 ? "The server is rate limiting requests. Wait before retrying." : response.status == 409 ? "The review changed. Reload before trying again." : "Review the server's branch and review requirements, then reload."
            throw GitFailure("Hosting API returned HTTP \(response.status). " + advice)
        }
        return response.data
    }
    func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitFailure("Invalid hosting API response.") }; return result
    }
    func array(_ data: Data) throws -> [[String: Any]] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw GitFailure("Invalid hosting list response.") }; return result
    }
    private func review(_ value: [String: Any]) throws -> HostedReview {
        let github = repository.provider == .github
        let head = value["head"] as? [String: Any], base = value["base"] as? [String: Any]
        let author = (value[github ? "user" : "author"] as? [String: Any])?[github ? "login" : "username"] as? String ?? "Unknown"
        guard let number = value[github ? "number" : "iid"] as? Int, number > 0,
              let title = value["title"] as? String, let raw = value[github ? "html_url" : "web_url"] as? String,
              let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              (url.host ?? "").lowercased() == repository.host.split(separator: ":").first.map(String.init) else { throw GitFailure("The review response did not match this host.") }
        return HostedReview(number: number, title: title, body: value[github ? "body" : "description"] as? String ?? "", author: author,
            source: (github ? head?["ref"] : value["source_branch"]) as? String ?? "", target: (github ? base?["ref"] : value["target_branch"]) as? String ?? "",
            head: (github ? head?["sha"] : value["sha"]) as? String ?? "", state: value["merged_at"] is String ? "merged" : value["state"] as? String ?? "unknown", url: url,
            diffBase: (value["diff_refs"] as? [String: Any])?["base_sha"] as? String ?? "", diffStart: (value["diff_refs"] as? [String: Any])?["start_sha"] as? String ?? "")
    }
    public func list(state: String = "open", page: Int = 1) async throws -> [HostedReview] {
        let state = repository.provider == .gitlab && state == "open" ? "opened" : state
        let data = try await send(path: reviews, query: [URLQueryItem(name: "state", value: state), URLQueryItem(name: "per_page", value: "30"), URLQueryItem(name: "page", value: String(max(1, page)))])
        return try array(data).map(review)
    }
    public func detail(_ number: Int) async throws -> HostedReview { try review(object(await send(path: reviews + "/\(number)"))) }
    public func create(title: String, body: String, source: String, target: String, draft: Bool = true, sourceProject: String? = nil) async throws -> HostedReview {
        let fork = try sourceProject.flatMap { value -> HostedRepository? in
            guard !value.isEmpty else { return nil }
            return try HostedRepository(remote: "https://" + repository.host + "/" + value + ".git", provider: repository.provider)
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !source.isEmpty, !target.isEmpty, source != target || (fork != nil && fork != repository), title.count <= 250, body.utf8.count <= 100_000 else { throw GitFailure("Enter a title and different published branches/projects (description up to 100 KB).") }
        var route = reviews
        var fields: [String: HostedJSON] = repository.provider == .github ? ["title": .text(title), "body": .text(body), "head": .text(source), "base": .text(target), "draft": .flag(draft)] : ["title": .text(draft ? "Draft: " + title : title), "description": .text(body), "source_branch": .text(source), "target_branch": .text(target)]
        if let fork, fork != repository {
            if repository.provider == .github {
                let parts = fork.project.split(separator: "/").map(String.init)
                fields["head"] = .text(parts[0] + ":" + source); fields["head_repo"] = .text(parts[1])
            } else {
                let project = try object(await send(path: repository.route))
                guard let targetID = project["id"] as? Int, targetID > 0 else { throw GitFailure("The server did not identify the target project.") }
                fields["target_project_id"] = .number(targetID)
                route = fork.route + "/merge_requests"
            }
        }
        return try review(object(await send("POST", path: route, body: fields)))
    }
    public func files(_ number: Int, page: Int = 1) async throws -> [HostedReviewFile] {
        let github = repository.provider == .github
        let data = try await send(path: reviews + "/\(number)" + (github ? "/files" : "/diffs"), query: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(max(1, page)))])
        return try array(data).map { value in
            guard let path = value[github ? "filename" : "new_path"] as? String else { throw GitFailure("Invalid review file.") }
            return HostedReviewFile(path: path, previousPath: value[github ? "previous_filename" : "old_path"] as? String, status: value["status"] as? String ?? (value["deleted_file"] as? Bool == true ? "deleted" : "changed"), patch: value[github ? "patch" : "diff"] as? String)
        }
    }
    public func checks(_ review: HostedReview) async throws -> [HostedReviewCheck] {
        guard !review.head.isEmpty else { return [] }
        let github = repository.provider == .github
        let data = try await send(path: github ? repository.route + "/commits/" + HostedRepository.component(review.head) + "/check-runs" : reviews + "/\(review.number)/pipelines", query: [URLQueryItem(name: "per_page", value: "100")])
        let values = github ? try object(data)["check_runs"] as? [[String: Any]] ?? [] : try array(data)
        return values.map { HostedReviewCheck(id: String(describing: $0["id"] ?? ""), name: $0["name"] as? String ?? "Pipeline " + String(describing: $0["id"] ?? ""), status: $0["conclusion"] as? String ?? $0["status"] as? String ?? "unknown") }
    }
    public func comments(_ number: Int, page: Int = 1) async throws -> [HostedReviewComment] {
        let github = repository.provider == .github
        let route = github ? repository.route + "/issues/\(number)/comments" : reviews + "/\(number)/notes"
        return try array(await send(path: route, query: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(max(1, page)))])).compactMap { value in
            guard let id = value["id"] as? Int, let body = value["body"] as? String else { return nil }
            let author = value[github ? "user" : "author"] as? [String: Any]
            return HostedReviewComment(id: id, author: author?[github ? "login" : "username"] as? String ?? "Unknown", body: body)
        }
    }
    public func legacyChecks(_ review: HostedReview) async throws -> [HostedReviewCheck] {
        guard repository.provider == .github, !review.head.isEmpty else { return [] }
        let data = try await send(path: repository.route + "/commits/" + HostedRepository.component(review.head) + "/status")
        let values = try object(data)["statuses"] as? [[String: Any]] ?? []
        return values.map { HostedReviewCheck(id: "status-" + String(describing: $0["id"] ?? ""), name: $0["context"] as? String ?? "Commit Status", status: $0["state"] as? String ?? "unknown") }
    }
    public func setClosed(_ review: HostedReview, closed: Bool) async throws {
        let current = try await detail(review.number)
        guard current.head == review.head, current.state != "merged" else { throw GitFailure("This review changed or merged. Reload it before changing its state.") }
        let github = repository.provider == .github
        _ = try await send(github ? "PATCH" : "PUT", path: reviews + "/\(review.number)", body: github ? ["state": .text(closed ? "closed" : "open")] : ["state_event": .text(closed ? "close" : "reopen")])
    }
    public func comment(_ review: HostedReview, text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 100_000 else { throw GitFailure("Enter a comment up to 100 KB.") }
        _ = try await send("POST", path: repository.provider == .github ? repository.route + "/issues/\(review.number)/comments" : reviews + "/\(review.number)/notes", body: ["body": .text(text)])
    }
    public func approve(_ review: HostedReview, comment: String = "", requestChanges: Bool = false) async throws {
        guard !review.head.isEmpty else { throw GitFailure("Reload the review before submitting feedback.") }
        if repository.provider == .github {
            if requestChanges && comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw GitFailure("Explain the changes you are requesting.") }
            _ = try await send("POST", path: reviews + "/\(review.number)/reviews", body: ["commit_id": .text(review.head), "body": .text(comment), "event": .text(requestChanges ? "REQUEST_CHANGES" : "APPROVE")])
        } else {
            guard !requestChanges else { throw GitFailure("Use a comment to request changes on this GitLab server.") }
            _ = try await send("POST", path: reviews + "/\(review.number)/approve", body: ["sha": .text(review.head)])
        }
    }
    public func merge(_ review: HostedReview, squash: Bool) async throws {
        guard !review.head.isEmpty, ["open", "opened"].contains(review.state) else { throw GitFailure("Reload an open review before merging.") }
        let github = repository.provider == .github
        let fields: [String: HostedJSON] = github ? ["sha": .text(review.head), "merge_method": .text(squash ? "squash" : "merge")] : ["sha": .text(review.head), "squash": .flag(squash), "should_remove_source_branch": .flag(false)]
        let result = try object(await send("PUT", path: reviews + "/\(review.number)/merge", body: fields))
        guard github ? result["merged"] as? Bool == true : result["state"] as? String == "merged" else { throw GitFailure("The server has not confirmed a completed merge. Reload to inspect its status; do not retry blindly.") }
    }
}
