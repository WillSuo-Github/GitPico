import Foundation
import Security

public struct GitStoredCredential: Codable, Sendable {
    public let host: String
    public let username: String
    public let secret: String
    public let oauth: OAuthAuthorization?
    public init(host: String, username: String, secret: String, oauth: OAuthAuthorization? = nil) { self.host = host.lowercased(); self.username = username; self.secret = secret; self.oauth = oauth }
}
public struct GitCredentialReference: Sendable {
    public let id: UUID
    public let host: String
    public let executable: String
    public init(id: UUID, host: String, executable: String) { self.id = id; self.host = host.lowercased(); self.executable = executable }
    var helper: String { "!" + shellQuote(executable) + " --gitpico-credential-helper" }
}
public enum GitCredentialVault {
    private static let service = "com.willsuo.GitPico.credentials"
    private static func query(_ id: UUID) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString] }
    public static func save(_ value: GitStoredCredential, id: UUID) throws {
        guard !value.host.isEmpty, !value.username.contains(where: { $0.isNewline || $0 == "\0" }), !value.secret.isEmpty, !value.secret.contains(where: { $0.isNewline || $0 == "\0" }), value.secret.utf8.count < 16_384 else { throw GitFailure("Enter a host, username and token without line breaks.") }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 65_536, value.oauth.map({ $0.configuration.host == value.host && ($0.refreshToken?.utf8.count ?? 0) < 16_384 }) ?? true else { throw GitFailure("Invalid OAuth credential data.") }
        var entry = query(id); entry[kSecValueData as String] = data
        entry[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(entry as CFDictionary, nil)
        if result == errSecDuplicateItem {
            var lookup = query(id); lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            try check(SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary))
        }
        else { try check(result) }
    }
    public static func read(_ id: UUID) throws -> GitStoredCredential {
        var request = query(id)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        try check(SecItemCopyMatching(request as CFDictionary, &result))
        guard let data = result as? Data else { throw GitFailure("No readable Keychain credential was found.") }
        return try JSONDecoder().decode(GitStoredCredential.self, from: data)
    }
    public static func remove(_ id: UUID) throws {
        var request = query(id); request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let result = SecItemDelete(request as CFDictionary)
        if result != errSecItemNotFound { try check(result) }
    }
    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw GitFailure("Keychain could not access this credential (\(status)). Unlock Keychain or save the credential again.") }
    }
}
public enum GitCredentialHelper {
    public static func response(operation: String, input: String, credential: GitStoredCredential, expectedHost: String) -> String {
        guard operation == "get", input.utf8.count < 16_384 else { return "" }
        var values: [String: String] = [:]
        for line in input.split(separator: "\n") {
            let fields = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if fields.count == 2 { values[String(fields[0])] = String(fields[1]) }
        }
        let genericGitLabUser = credential.oauth?.configuration.provider == .gitlab && values["username"] == "oauth2"
        guard values["protocol"] == "https", values["host"]?.lowercased() == expectedHost.lowercased(), credential.host == expectedHost.lowercased(), values["username"].map({ $0 == credential.username || genericGitLabUser }) ?? true, !credential.username.contains(where: { $0.isNewline || $0 == "\0" }), !credential.secret.contains(where: { $0.isNewline || $0 == "\0" }) else { return "" }
        return "username=" + (genericGitLabUser ? "oauth2" : credential.username) + "\npassword=" + credential.secret + "\n\n"
    }
    public static func run(arguments: [String], environment: [String: String]) {
        guard arguments.last == "get", let raw = environment["GITPICO_CREDENTIAL_ID"], let id = UUID(uuidString: raw), let host = environment["GITPICO_CREDENTIAL_HOST"] else { return }
        let input = String(decoding: (try? FileHandle.standardInput.read(upToCount: 16_384)) ?? Data(), as: UTF8.self)
        let lines = input.split(separator: "\n").map(String.init)
        guard lines.contains("protocol=https"), lines.contains(where: { $0.lowercased() == "host=" + host.lowercased() }) else { return }
        do {
            let credential = try OAuthCredentialRefresher.forGit(id)
            let output = response(operation: "get", input: input, credential: credential, expectedHost: host)
            if !output.isEmpty { try FileHandle.standardOutput.write(contentsOf: Data(output.utf8)) }
        } catch {
            let message = "GitPico authentication: " + GitLogRedaction.clean(error.localizedDescription) + "\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        }
    }
}
