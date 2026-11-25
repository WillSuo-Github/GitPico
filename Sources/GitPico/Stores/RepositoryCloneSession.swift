import Foundation
import GitCore

struct RepositoryCloneSession: Identifiable, Equatable {
    struct TransferMetrics: Equatable {
        let stage: String
        let percent: Int
        let counts: String?
        let transferred: String?
        let rate: String?
        var fraction: Double { Double(percent) / 100 }

        var formattedCounts: String? {
            guard let counts else { return nil }
            let parts = counts.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let current = Int(parts[0]), let total = Int(parts[1]) {
                return "\(current.formatted()) / \(total.formatted())"
            }
            return counts
        }

        var detailSummary: String? {
            let items = [formattedCounts, transferred, rate].compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            return items.isEmpty ? nil : items.joined(separator: " · ")
        }

        static func latest(in output: String) -> Self? {
            let progressLine = #/^(?:remote: )?(Counting objects|Compressing objects|Receiving objects|Writing objects|Resolving deltas|Unpacking objects|Updating files|Checking out files|Filtering content|Uploading LFS objects|Downloading LFS objects):\s*([0-9]{1,3})%\s+\(([^)]+)\)(.*)$/#
            for line in output.split(whereSeparator: \.isNewline).reversed() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let match = trimmed.firstMatch(of: progressLine), let percent = Int(match.2), percent <= 100 {
                    let counts = match.3.trimmingCharacters(in: .whitespaces)
                    let (transferred, rate) = parseTransferDetails(String(match.4))
                    return Self(
                        stage: String(match.1),
                        percent: percent,
                        counts: counts.isEmpty ? nil : counts,
                        transferred: transferred,
                        rate: rate
                    )
                }
            }
            return nil
        }

        private static func parseTransferDetails(_ raw: String) -> (transferred: String?, rate: String?) {
            var remainder = raw.trimmingCharacters(in: .whitespaces)
            if remainder.hasPrefix(",") {
                remainder = String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if let doneRange = remainder.range(of: #",?\s*done\.?$"#, options: .regularExpression) {
                remainder.removeSubrange(doneRange)
                remainder = remainder.trimmingCharacters(in: .whitespaces)
            }
            guard !remainder.isEmpty else { return (nil, nil) }
            let pieces = remainder.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pieces.count == 2 {
                let transferred = pieces[0].isEmpty ? nil : pieces[0]
                let rate = pieces[1].isEmpty ? nil : pieces[1]
                return (transferred, rate)
            }
            if remainder.hasSuffix("/s") {
                return (nil, remainder)
            }
            return (remainder, nil)
        }
    }

    enum Phase: Equatable {
        case cloning
        case opening
        case cancelled
        case failed(String)
    }

    enum Step: Int, CaseIterable, Comparable, Identifiable {
        case connect = 0
        case download = 1
        case checkout = 2
        case open = 3

        var id: Int { rawValue }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var title: String {
            switch self {
            case .connect: String(localized: "Connect")
            case .download: String(localized: "Download")
            case .checkout: String(localized: "Checkout")
            case .open: String(localized: "Open")
            }
        }
    }

    let id: UUID
    let name: String
    let destination: URL
    let source: String
    let displaySource: String
    let recursive: Bool
    let lfs: LFSCloneMode
    let allowLocalTransport: Bool
    let profileID: UUID?
    let started: Date
    var finished: Date? = nil
    var phase: Phase = .cloning
    var reachedStep: Step = .connect
    var isCancelling = false
    var networkRecordID: UUID? = nil
    var output: String = ""
    var timedOut = false
    var activeSubmodule: String? = nil

    init(
        id: UUID = UUID(),
        destination: URL,
        source: String,
        recursive: Bool = false,
        lfs: LFSCloneMode = .inherit,
        allowLocalTransport: Bool = false,
        profileID: UUID? = nil,
        started: Date = Date()
    ) {
        self.id = id
        self.name = destination.lastPathComponent
        self.destination = destination
        self.source = source
        self.displaySource = Self.sanitizedDisplaySource(source)
        self.recursive = recursive
        self.lfs = lfs
        self.allowLocalTransport = allowLocalTransport
        self.profileID = profileID
        self.started = started
    }

    var isRunning: Bool {
        phase == .cloning || phase == .opening
    }

    var canCancel: Bool {
        phase == .cloning && !isCancelling
    }

    var transferProgress: TransferMetrics? {
        phase == .cloning ? TransferMetrics.latest(in: output) : nil
    }

    var activeStep: Step {
        phase == .opening ? .open : reachedStep
    }

    var destinationExistsOnDisk: Bool {
        FileManager.default.fileExists(atPath: destination.path)
    }

    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    var isAuthenticationFailure: Bool {
        let combined = (output + "\n" + (failureMessage ?? "")).lowercased()
        return [
            "authentication failed", "permission denied", "could not read username",
            "could not read password", "invalid username or token",
            "returned error: 401", "returned error: 403", "http 401", "http 403"
        ].contains { combined.contains($0) }
    }

    var headline: String {
        switch phase {
        case .cloning:
            if isCancelling { return String(localized: "Cancelling clone…") }
            if let progress = transferProgress { return progress.stage }
            if let hint = Self.latestStatusStage(in: output) { return hint.title }
            return String(localized: "Connecting to remote…")
        case .opening:
            return String(localized: "Opening repository…")
        case .cancelled:
            return String(localized: "Clone cancelled")
        case .failed:
            return String(localized: "Clone failed")
        }
    }

    var subheadline: String {
        switch phase {
        case .cloning:
            if isCancelling {
                return String(localized: "Stopping Git and leaving any downloaded files untouched.")
            }
            if let detail = transferProgress?.detailSummary {
                return detail
            }
            if let hint = Self.latestStatusStage(in: output), let detail = hint.detail {
                return detail
            }
            return String(localized: "Negotiating with the remote repository…")
        case .opening:
            return String(localized: "Loading branches, status and commit history…")
        case .cancelled:
            return String(localized: "The clone stopped before finishing.")
        case .failed(let message):
            let cleaned = GitLogRedaction.clean(message)
            let firstLine = cleaned
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return firstLine ?? String(localized: "Git could not finish cloning this repository.")
        }
    }

    var latestOutputLine: String? {
        output
            .split(whereSeparator: \.isNewline)
            .reversed()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    var retryRequest: RepositoryCreationRequest {
        RepositoryCreationRequest(
            clone: true,
            source: source,
            name: name,
            profileID: profileID,
            parent: destination.deletingLastPathComponent(),
            recursive: recursive,
            enableLFS: lfs != .inherit,
            downloadLFS: lfs != .pointersOnly,
            allowLocalTransport: allowLocalTransport
        )
    }

    mutating func apply(_ event: GitNetworkEvent) {
        if event.phase == .running, phase != .cloning { return }
        if networkRecordID == nil || event.phase == .running {
            networkRecordID = event.id
        }
        let cleaned = GitLogRedaction.clean(String(decoding: Data(event.output.utf8.suffix(32_768)), as: UTF8.self))
        if !cleaned.isEmpty {
            output = cleaned
            let inferred = Self.inferStep(from: cleaned)
            if inferred > reachedStep { reachedStep = inferred }
            if let submodule = Self.latestSubmoduleName(in: cleaned) {
                activeSubmodule = submodule
            }
        }
        if event.timedOut { timedOut = true }
        if event.phase == .cancelled, phase == .cloning {
            phase = .cancelled
            isCancelling = false
            finished = Date()
        }
    }

    static func inferStep(from output: String) -> Step {
        var step = Step.connect
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Resolving deltas:") ||
                line.hasPrefix("Unpacking objects:") ||
                line.hasPrefix("Updating files:") ||
                line.hasPrefix("Checking out files:") ||
                line.hasPrefix("Filtering content:") ||
                line.hasPrefix("Downloading LFS objects:") ||
                line.hasPrefix("Submodule ") ||
                line.hasPrefix("Submodule path ") {
                return .checkout
            }
            if line.hasPrefix("Receiving objects:") {
                step = max(step, .download)
            }
        }
        return step
    }

    static func latestSubmoduleName(in output: String) -> String? {
        let registered = #/^Submodule '([^']+)' /#
        let submodulePath = #/^Submodule path '([^']+)':/#
        for rawLine in output.split(whereSeparator: \.isNewline).reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let match = line.firstMatch(of: submodulePath) {
                return String(match.1)
            }
            if let match = line.firstMatch(of: registered) {
                return String(match.1)
            }
        }
        return nil
    }

    private static func latestStatusStage(in output: String) -> (title: String, detail: String?)? {
        let enumerating = #/^(?:remote: )?Enumerating objects:\s*([0-9]+)(?:,\s*done\.?)?/#
        for rawLine in output.split(whereSeparator: \.isNewline).reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let match = line.firstMatch(of: enumerating) {
                let count = Int(match.1).map { $0.formatted() } ?? String(match.1)
                return (String(localized: "Enumerating objects"), String(localized: "\(count) objects discovered"))
            }
            if line.hasPrefix("Submodule ") || line.hasPrefix("Submodule path ") {
                return (String(localized: "Initializing submodules…"), line)
            }
            if line.hasPrefix("Checking connectivity") {
                return (String(localized: "Verifying objects…"), nil)
            }
        }
        return nil
    }

    static func sanitizedDisplaySource(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let schemeRange = trimmed.range(of: "://"), !trimmed[..<schemeRange.lowerBound].contains("/") {
            if var components = URLComponents(string: trimmed) {
                if components.scheme?.lowercased() == "file" {
                    return Pico.abbreviated(components.path)
                }
                components.user = nil
                components.password = nil
                components.query = nil
                components.fragment = nil
                if let host = components.host, !host.isEmpty {
                    let portSuffix = components.port.map { ":\($0)" } ?? ""
                    var path = components.path
                    if path.hasSuffix(".git") { path.removeLast(4) }
                    return host + portSuffix + path
                }
            }
            return String(localized: "Remote repository")
        }

        if let scpMatch = trimmed.firstMatch(of: #/^(?:([^@:\s]+)@)?(\[[^\]/]+\]|[^/:\s]+):(.+)$/#) {
            let host = String(scpMatch.2)
            var path = String(scpMatch.3)
            if path.hasSuffix(".git") { path.removeLast(4) }
            let userPrefix = scpMatch.1.map { $0 == "git" ? "" : "\($0)@" } ?? ""
            return "\(userPrefix)\(host)/\(path)"
        }

        return Pico.abbreviated(trimmed)
    }
}
