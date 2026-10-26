import Foundation
import Security

public struct GitStoredCredential: Codable, Sendable {
    public let host: String
    public let username: String
    public let secret: String
    public init(host: String, username: String, secret: String) { self.host = host.lowercased(); self.username = username; self.secret = secret }
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
        guard values["protocol"] == "https", values["host"]?.lowercased() == expectedHost.lowercased(), credential.host == expectedHost.lowercased(), values["username"].map({ $0 == credential.username }) ?? true, !credential.username.contains(where: { $0.isNewline || $0 == "\0" }), !credential.secret.contains(where: { $0.isNewline || $0 == "\0" }) else { return "" }
        return "username=" + credential.username + "\npassword=" + credential.secret + "\n\n"
    }
    public static func run(arguments: [String], environment: [String: String]) {
        guard let raw = environment["GITPICO_CREDENTIAL_ID"], let id = UUID(uuidString: raw), let host = environment["GITPICO_CREDENTIAL_HOST"], let credential = try? GitCredentialVault.read(id) else { return }
        let input = String(decoding: (try? FileHandle.standardInput.read(upToCount: 16_384)) ?? Data(), as: UTF8.self)
        let output = response(operation: arguments.last ?? "", input: input, credential: credential, expectedHost: host)
        if !output.isEmpty { try? FileHandle.standardOutput.write(contentsOf: Data(output.utf8)) }
    }
}
