import AppKit
import Foundation
import GitCore
import UniformTypeIdentifiers

@MainActor enum DiagnosticExporter {
    static func data(store: RepositoryStore) throws -> Data {
        let bundle = Bundle.main
        var packet: [String: Any] = [
            "format": 1,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Development",
            "minimumOS": bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "26.0",
            "hostOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architecture,
            "network": (store.networkActivity?.records ?? []).prefix(30).map { record -> [String: Any] in
                ["command": record.command, "phase": record.phase.rawValue, "started": ISO8601DateFormatter().string(from: record.started), "duration": record.finished.map { $0.timeIntervalSince(record.started) } ?? 0]
            },
            "accounts": ["count": store.authentication.profiles.count, "oauthCount": store.authentication.profiles.filter(\.isOAuth).count],
            "privacy": "File contents, commit messages, repository names/paths, URLs, raw logs and credentials are excluded."
        ]
        if let snapshot = store.snapshot {
            packet["repository"] = ["hasHEAD": snapshot.hasHEAD, "detached": snapshot.head.branch == "HEAD", "operation": snapshot.operation.rawValue,
                "changedFiles": snapshot.changes.count, "conflictedFiles": snapshot.changes.filter(\.isConflicted).count,
                "ahead": snapshot.ahead, "behind": snapshot.behind, "upstreamMissing": snapshot.unresolvedUpstream != nil,
                "loadedCommits": snapshot.commits.count, "remoteCount": snapshot.remotes.count]
        }
        return try JSONSerialization.data(withJSONObject: packet, options: [.prettyPrinted, .sortedKeys])
    }
    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
    static func export(store: RepositoryStore, completion: @escaping @MainActor (String) -> Void) {
        do {
            let bytes = try data(store: store)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "GitPico-diagnostics-" + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + ".json"
            panel.title = String(localized: "Export Diagnostics")
            panel.message = String(localized: "Exports app/build and repository state counts. File contents, raw logs, names, paths, URLs and credentials are excluded.")
            panel.begin { result in
                guard result == .OK, let url = panel.url else { return }
                do {
                    if FileManager.default.fileExists(atPath: url.path), try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType != .typeRegular { throw appFailure("Choose a regular diagnostic file destination.") }
                    try bytes.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    completion(String(localized: "Diagnostics exported."))
                } catch { completion(error.localizedDescription) }
            }
        } catch { completion(error.localizedDescription) }
    }
}
