import Foundation

/// Opt-in command timing. Arguments, paths and command output are never captured.
public struct GitCommandSample: Codable, Sendable {
    public let phase: String
    public let command: String
    public let seconds: Double
    public let failed: Bool
}
public actor GitCommandTrace {
    @TaskLocal public static var current: GitCommandTrace?
    @TaskLocal public static var phase = "other"
    public private(set) var samples: [GitCommandSample] = []
    public init() {}
    func record(command: String, phase: String, elapsed: Duration, failed: Bool) {
        samples.append(GitCommandSample(phase: phase, command: command, seconds: elapsed.secondsValue, failed: failed))
    }
}
extension Duration {
    public var secondsValue: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
