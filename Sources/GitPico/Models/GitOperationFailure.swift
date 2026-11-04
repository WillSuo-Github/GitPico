import Foundation
import GitCore

/// An immutable, bounded presentation of a failure, independent of the live operation.
struct GitOperationFailure: Identifiable, Equatable {
    let id = UUID()
    let summary: String
    let details: String
    let omittedEarlierOutput: Bool

    init(_ output: String) {
        details = GitLogRedaction.clean(output)
        omittedEarlierOutput = output.count > 32_768 || output.contains("[Earlier Git output omitted.]")
        let progress = /^(?:remote:\s*)?(?:Enumerating objects|Counting objects|Compressing objects|Receiving objects|Writing objects|Resolving deltas|Unpacking objects|Updating files|Checking out files|Uploading LFS objects|Downloading LFS objects):\s*(?:[0-9]+%\s+\(.*|[0-9]+,?\s+done\.)$/
        let lines = details.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "[Earlier Git output omitted.]" && $0.firstMatch(of: progress) == nil }
        let diagnostic = lines.filter {
            let lower = $0.lowercased()
            return ["fatal:", "error:", "remote: error:", "remote: fatal:", "! [rejected]", "! [remote rejected]"].contains { lower.hasPrefix($0) }
        }
        let selected = diagnostic.isEmpty ? Array(lines.suffix(3)) : Array(diagnostic.prefix(3))
        let text = selected.map { Self.bounded($0, limit: 160) }.joined(separator: "\n")
        summary = text.isEmpty
            ? String(localized: "Git did not complete successfully. Open details to inspect the output.")
            : Self.bounded(text, limit: 420)
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        value.count > limit ? String(value.prefix(limit - 1)) + "…" : value
    }
}
