import Foundation
import Testing
@testable import GitCore

@Test func managedSSHKeyGenerationNeverOverwritesExistingKeys() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitPico-SSH-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SSHKeyManager(directory: directory)
    let key = try await manager.generate(name: "fixture_ed25519", comment: "acceptance@example.invalid")
    #expect(key.publicKey.hasPrefix("ssh-ed25519 ") && key.fingerprint.contains("ED25519"))
    let original = try Data(contentsOf: key.privateFile)
    let permissions = try FileManager.default.attributesOfItem(atPath: key.privateFile.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    await #expect(throws: GitFailure.self) { try await manager.generate(name: "fixture_ed25519", comment: "replace") }
    #expect(try Data(contentsOf: key.privateFile) == original)
    await #expect(throws: GitFailure.self) { try await manager.generate(name: "../escape", comment: "invalid") }
    #expect(try await manager.keys().count == 1)
}
