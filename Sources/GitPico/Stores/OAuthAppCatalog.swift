import Foundation
import GitCore

enum OAuthAppCatalog {
    // Public client identifiers. No client secret is used by either native flow.
    static func configuration(_ provider: OAuthProvider) throws -> OAuthConfiguration {
        switch provider {
        case .github: try OAuthConfiguration(provider: .github, host: "github.com", clientID: "Ov23liSrQZqjI0HkLbHN")
        case .gitlab: try OAuthConfiguration(provider: .gitlab, host: "gitlab.com", clientID: "5841c443bb4aa0e5e369e1abe79518770aa78f859ebf6e519196de34b53f12c8")
        }
    }
}
