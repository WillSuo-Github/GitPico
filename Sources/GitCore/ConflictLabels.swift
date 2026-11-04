import Foundation

public struct ConflictLabels: Sendable {
    public let current: String
    public let incoming: String
}

extension GitRepository {
    public func conflictLabels() async throws -> ConflictLabels {
        let head = try await headPosition()
        func label(_ revision: String, fallback: String) async throws -> String {
            let resolved = try await GitProcess.run(["rev-parse", "--verify", "--quiet", "--end-of-options", revision + "^{commit}"], at: root, allowed: [0, 1, 128])
            guard resolved.status == 0 else { return fallback }
            let hash = resolved.text.trimmingCharacters(in: .newlines)
            let name = try await GitProcess.run(["name-rev", "--name-only", "--no-undefined", hash], at: root, allowed: [0, 1, 128])
            let value = name.status == 0 ? name.text.trimmingCharacters(in: .newlines) : ""
            return (value.isEmpty ? fallback : value) + " · " + hash.prefix(8)
        }
        let current = head.branch.hasPrefix("refs/heads/") ? String(head.branch.dropFirst(11)) + " · " + (head.hash?.prefix(8) ?? "") : try await label("HEAD", fallback: localized("Current"))
        let operation = try await currentOperation()
        let source: String
        switch operation {
        case .merge: source = "MERGE_HEAD"
        case .rebase: source = "REBASE_HEAD"
        case .cherryPick: source = "CHERRY_PICK_HEAD"
        case .revert: source = "REVERT_HEAD"
        case .none: return ConflictLabels(current: current, incoming: localized("Incoming"))
        }
        let incoming = try await label(source, fallback: operation == .rebase ? localized("Replayed commit") : localized("Incoming"))
        // Revert's incoming side is the selected commit's parent, not the commit
        // being reverted; keep the semantic label explicit instead of mislabelling it.
        return ConflictLabels(current: current, incoming: operation == .revert ? localized("Version before reverted commit") : incoming)
    }
}
