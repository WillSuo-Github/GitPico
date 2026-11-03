import Foundation
import GitCore

struct AccountRepository: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let fullName: String
    let cloneURL: URL
    let isRestricted: Bool
    let keys: Set<HostedRepositoryKey>
}

struct HostedRepositoryKey: Hashable, Sendable {
    let host: String
    let project: String

    init?(remote: String, provider: OAuthProvider) {
        guard let parsed = try? HostedRepository(remote: remote, provider: provider) else { return nil }
        // A standard HTTPS port and GitHub's official SSH-over-443 endpoint
        // are alternate spellings for the same repository.
        let address = parsed.host.hasSuffix(":443") ? String(parsed.host.dropLast(4)) : parsed.host
        let isSSH = !remote.lowercased().hasPrefix("https://")
        host = provider == .github && isSSH && address == "ssh.github.com" ? "github.com" : address
        project = provider == .github ? parsed.project.lowercased() : parsed.project
    }
}

extension AuthenticationProfile {
    var repositoryProvider: OAuthProvider? {
        switch provider {
        case .github: .github
        case .gitlab: .gitlab
        case .generic: nil
        }
    }

    var repositoryAccountLabel: String {
        let publicHost = provider == .github ? "github.com" : "gitlab.com"
        let location = host == publicHost ? username : username + " @ " + host
        return provider.rawValue + " · " + location
    }
}

enum AccountRepositoryClient {
    static func list(
        _ profile: AuthenticationProfile, credential: GitStoredCredential,
        transport: any OAuthHTTPTransport = OAuthHTTPSClient(maximumResponseBytes: 4 * 1024 * 1024)
    ) async throws -> [AccountRepository] {
        guard let provider = profile.repositoryProvider else { return [] }
        if provider == .gitlab, let authorization = credential.oauth,
           !authorization.scopes.contains("read_api"), !authorization.scopes.contains("api") {
            throw appFailure("Sign in to GitLab again in Settings → Authentication to allow GitPico to list your projects.")
        }
        var request = try HostingAccountClient.request(profile, credential: credential, listingRepositories: true)
        guard let endpoint = request.url, var first = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw appFailure("Invalid hosting API URL.")
        }
        first.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        if provider == .github {
            first.queryItems?.append(URLQueryItem(name: "sort", value: "full_name"))
        } else {
            first.queryItems?.append(contentsOf: [
                URLQueryItem(name: "membership", value: "true"),
                URLQueryItem(name: "pagination", value: "keyset"),
                URLQueryItem(name: "order_by", value: "id"),
                URLQueryItem(name: "sort", value: "asc"),
            ])
        }
        var next = first.url
        var seen: Set<URL> = []
        var repositories: [Int64: AccountRepository] = [:]
        while let url = next {
            try Task.checkCancellation()
            guard url.scheme == endpoint.scheme, url.host == endpoint.host, url.port == endpoint.port,
                  url.path == endpoint.path, url.user == nil, url.password == nil, url.fragment == nil,
                  seen.insert(url).inserted else {
                throw appFailure("The hosting service returned an invalid repository page link.")
            }
            request.url = url
            let response = try await transport.send(request)
            switch response.status {
            case 200: break
            case 401, 403:
                throw appFailure("Could not access this account’s repositories. Check its permissions or sign in again in Settings → Authentication.")
            case 429:
                throw appFailure("The hosting service is limiting requests. Try again later.")
            default:
                throw appFailure("Could not load repositories from this hosting service.")
            }
            for repository in try decode(response.data, provider: provider, host: profile.host) {
                repositories[repository.id] = repository
            }
            next = try nextURL(response, current: url, provider: provider)
        }
        return repositories.values.sorted {
            let order = $0.fullName.localizedStandardCompare($1.fullName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private struct GitHubRow: Decodable {
        let id: Int64
        let name: String
        let full_name: String
        let clone_url: String
        let ssh_url: String?
        let `private`: Bool
    }

    private struct GitLabRow: Decodable {
        let id: Int64
        let path: String
        let path_with_namespace: String
        let http_url_to_repo: String
        let ssh_url_to_repo: String?
        let visibility: String
    }

    private static func decode(_ data: Data, provider: OAuthProvider, host: String) throws -> [AccountRepository] {
        func entry(_ id: Int64, _ name: String, _ fullName: String, _ remote: String, _ ssh: String?, _ restricted: Bool) throws -> AccountRepository {
            guard let url = URL(string: remote), url.scheme == "https", url.user == nil,
                  url.password == nil, url.query == nil, url.fragment == nil,
                  let key = HostedRepositoryKey(remote: remote, provider: provider),
                  let expected = HostedRepositoryKey(remote: "https://" + host + "/sample/repository", provider: provider),
                  key.host == expected.host else {
                throw appFailure("The hosting service returned an invalid repository URL.")
            }
            var keys: Set<HostedRepositoryKey> = [key]
            if let ssh, ssh.hasPrefix("ssh://") || ssh.hasPrefix("git@"),
               let alias = HostedRepositoryKey(remote: ssh, provider: provider), alias.project == key.project {
                keys.insert(alias)
            }
            return AccountRepository(id: id, name: name, fullName: fullName, cloneURL: url, isRestricted: restricted, keys: keys)
        }

        do {
            let decoder = JSONDecoder()
            switch provider {
            case .github:
                return try decoder.decode([GitHubRow].self, from: data).map { try entry($0.id, $0.name, $0.full_name, $0.clone_url, $0.ssh_url, $0.private) }
            case .gitlab:
                return try decoder.decode([GitLabRow].self, from: data).map { try entry($0.id, $0.path, $0.path_with_namespace, $0.http_url_to_repo, $0.ssh_url_to_repo, $0.visibility != "public") }
            }
        } catch is DecodingError {
            throw appFailure("The hosting service returned an unreadable repository list.")
        }
    }

    private static func nextURL(_ response: OAuthHTTPResponse, current: URL, provider: OAuthProvider) throws -> URL? {
        // Parse the URL inside angle brackets before reading relation attributes;
        // the URL itself may include commas or semicolons.
        if let link = response.link {
            for match in link.matches(of: /<([^>]+)>\s*((?:;[^<,]*)?)/) {
                let attributes = match.2.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                guard attributes.contains("rel=\"next\"") || attributes.contains("rel=next") else { continue }
                guard let next = URL(string: String(match.1), relativeTo: current)?.absoluteURL else {
                    throw appFailure("The hosting service returned an invalid repository page link.")
                }
                return next
            }
        }
        guard provider == .gitlab, let page = response.nextPage, !page.isEmpty else { return nil }
        guard let number = Int(page), number > 0, var components = URLComponents(url: current, resolvingAgainstBaseURL: false) else {
            throw appFailure("The hosting service returned an invalid repository page link.")
        }
        var items = (components.queryItems ?? []).filter { !["page", "pagination"].contains($0.name) }
        items.append(URLQueryItem(name: "page", value: String(number)))
        components.queryItems = items
        return components.url
    }
}

enum LocalHostedRepositoryIndex {
    static func keys(at location: URL, provider: OAuthProvider, requireExactRoot: Bool = true) async throws -> (URL, Set<HostedRepositoryKey>) {
        let repository = try await GitRepository.open(location)
        let root = await repository.root
        guard !requireExactRoot || root.path == location.standardizedFileURL.resolvingSymlinksInPath().path else { return (root, []) }
        let remotes = try await repository.remoteConfigurations()
        // A fork often has an upstream remote. Prefer the clone's origin so the
        // fork is not also presented as a checkout of its upstream project.
        let primary = remotes.first(where: { $0.name == "origin" }).map { [$0] } ?? remotes
        return (root, Set(primary.compactMap { HostedRepositoryKey(remote: $0.fetchURL, provider: provider) }))
    }

    static func load(paths: Set<String>, provider: OAuthProvider) async -> [HostedRepositoryKey: Set<String>] {
        var index: [HostedRepositoryKey: Set<String>] = [:]
        let paths = Array(paths)
        for start in stride(from: 0, to: paths.count, by: 8) {
            guard !Task.isCancelled else { break }
            await withTaskGroup(of: (String, Set<HostedRepositoryKey>).self) { group in
                for path in paths[start..<min(start + 8, paths.count)] {
                    group.addTask {
                        let result = try? await keys(at: URL(fileURLWithPath: path), provider: provider)
                        return (path, result?.1 ?? [])
                    }
                }
                for await (path, keys) in group {
                    for key in keys { index[key, default: []].insert(path) }
                }
            }
        }
        return index
    }
}
