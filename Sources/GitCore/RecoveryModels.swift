import Foundation

public struct HeadPosition: Codable, Equatable, Sendable {
    public let branch: String
    public let hash: String?
    public init(branch: String, hash: String?) { self.branch = branch; self.hash = hash }
}

public struct UndoRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let title: String
    public let before: HeadPosition
    public let after: HeadPosition
    public let restoresFiles: Bool
    public let date: Date
}

public struct UndoAvailability: Sendable {
    public let undo: UndoRecord?
    public let redo: UndoRecord?
}

struct UndoJournal: Codable {
    var undo: [UndoRecord] = []
    var redo: [UndoRecord] = []
}

struct PendingHistoryAction: Codable {
    let before: HeadPosition
    let title: String
    let operation: RepositoryOperation
}

public struct ReflogEntry: Identifiable, Sendable {
    public var id: String { selector + hash + String(date.timeIntervalSince1970) }
    public let selector: String
    public let hash: String
    public let message: String
    public let name: String
    public let email: String
    public let date: Date
}
