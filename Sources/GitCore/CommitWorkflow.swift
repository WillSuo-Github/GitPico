import Foundation

public enum GitSignatureState: String, Sendable {
    case valid = "Valid signature", untrusted = "Valid signature, untrusted identity", invalid = "Invalid signature"
    case expired = "Expired signature or key", revoked = "Revoked key", unverifiable = "Cannot verify signature", unsigned = "Unsigned"
}
public struct GitSignature: Sendable {
    public let state: GitSignatureState
    public let signer: String
    public let key: String
    public let fingerprint: String
    public let diagnostic: String
}
extension GitRepository {
    public func configuredCommitTemplate() async throws -> String {
        let value = try await GitProcess.run(["config", "--path", "--get", "commit.template"], at: root, allowed: [0, 1])
        guard value.status == 0 else { throw GitFailure("No commit.template is configured for this repository.") }
        var path = value.text; if path.hasSuffix("\n") { path.removeLast() }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 256 * 1024 else { throw GitFailure("Commit templates must be regular UTF-8 files up to 256 KB.") }
        let data = try Data(contentsOf: url)
        guard data.count <= 256 * 1024, !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw GitFailure("Commit templates must be UTF-8 text without NUL bytes.") }
        return try await GitProcess.run(["stripspace", "--strip-comments"], at: root, input: data).text.trimmingCharacters(in: .newlines)
    }

    public func signature(of revision: String, tag: Bool = false) async throws -> GitSignature {
        if tag {
            let object = try await GitProcess.run(["rev-parse", "--verify", "--end-of-options", revision + "^{tag}"], at: root, allowed: [0, 128], cancellable: true)
            guard object.status == 0 else { throw GitFailure("Lightweight tags have no tag-object signature. Verify the target commit instead.") }
            let hash = object.text.trimmingCharacters(in: .newlines)
            let output = try await GitProcess.run(["verify-tag", "--raw", hash], at: root, allowed: [0, 1, 128], cancellable: true)
            let raw = output.error
            let state: GitSignatureState
            if raw.contains("REVKEYSIG") { state = .revoked }
            else if raw.contains("EXPKEYSIG") || raw.contains("EXPSIG") { state = .expired }
            else if raw.contains("BADSIG") { state = .invalid }
            else if output.status == 0 { state = raw.contains("TRUST_UNDEFINED") || raw.contains("TRUST_NEVER") ? .untrusted : .valid }
            else if raw.contains("no signature found") { state = .unsigned }
            else { state = .unverifiable }
            return GitSignature(state: state, signer: "", key: "", fingerprint: "", diagnostic: String(GitLogRedaction.clean(raw).prefix(8192)))
        }
        let hash = try await verifiedCommit(revision)
        let output = try await GitProcess.run(["show", "--no-patch", "--format=%G?%x00%GS%x00%GK%x00%GF", hash, "--"], at: root, cancellable: true)
        let values = output.text.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
        guard values.count == 4 else { throw GitFailure("Git did not return signature verification metadata.") }
        let state: GitSignatureState = switch values[0] { case "G": .valid; case "U": .untrusted; case "B": .invalid; case "X", "Y": .expired; case "R": .revoked; case "N": .unsigned; default: .unverifiable }
        return GitSignature(state: state, signer: values[1], key: values[2], fingerprint: values[3], diagnostic: String(GitLogRedaction.clean(output.error).prefix(8192)))
    }
}
