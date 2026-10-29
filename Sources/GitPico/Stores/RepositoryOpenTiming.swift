import Foundation
import GitCore
import OSLog

struct RepositoryOpenPhase: Codable, Sendable { let name: String; let seconds: Double }
struct RepositoryOpenReport: Codable, Sendable {
    let seconds: Double
    let succeeded: Bool
    let phases: [RepositoryOpenPhase]
}
@MainActor final class RepositoryOpenTiming {
    private static let logger = Logger(subsystem: "com.willsuo.GitPico", category: "RepositoryOpen")
    private let start = ContinuousClock.now
    private var phases: [RepositoryOpenPhase] = []
    func measure<T: Sendable>(_ name: String, _ operation: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        defer { phases.append(RepositoryOpenPhase(name: name, seconds: start.duration(to: .now).secondsValue)) }
        return try await GitCommandTrace.$phase.withValue(name) { try await operation() }
    }
    func finish(succeeded: Bool) -> RepositoryOpenReport {
        let seconds = start.duration(to: .now).secondsValue
        let detail = phases.map { $0.name + "=" + String(format: "%.3f", $0.seconds) }.joined(separator: " ")
        Self.logger.info("Repository open succeeded=\(succeeded, privacy: .public) seconds=\(seconds, privacy: .public) phases=\(detail, privacy: .public)")
        return RepositoryOpenReport(seconds: seconds, succeeded: succeeded, phases: phases)
    }
}
