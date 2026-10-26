import GitCore
import SwiftUI

@MainActor struct HostedReviewWebMenu: View {
    let store: RepositoryStore
    private var destinations: [(name: String, repository: HostedRepository)] {
        store.managedRemotes.compactMap { remote in
            guard let parsed = try? HostedRepository(remote: remote.fetchURL, provider: .gitlab) else { return nil }
            let provider: OAuthProvider
            switch parsed.host {
            case "github.com", "github.com:443": provider = .github
            case "gitlab.com", "gitlab.com:443": provider = .gitlab
            default:
                guard let account = store.authentication.profiles.first(where: { $0.host == parsed.host && $0.provider != .generic }) else { return nil }
                provider = account.provider == .github ? .github : .gitlab
            }
            guard let repository = try? HostedRepository(remote: remote.fetchURL, provider: provider) else { return nil }
            return (remote.name, repository)
        }
    }
    var body: some View {
        let links = destinations
        if links.count == 1, let link = links.first {
            Link(destination: link.repository.reviewsWebURL) {
                Label(link.repository.provider == .github ? "Pull Requests on GitHub" : "Merge Requests on GitLab", systemImage: "arrow.up.right.square")
            }.help("Open in your browser")
        } else if !links.isEmpty {
            Menu {
                ForEach(links, id: \.name) { link in
                    Link(link.name + " · " + link.repository.project, destination: link.repository.reviewsWebURL)
                }
            } label: { Label("Pull / Merge Requests on Web", systemImage: "arrow.up.right.square") }
        }
    }
}
