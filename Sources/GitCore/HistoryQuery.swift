import Foundation

/// A small, literal query language. Values may be quoted; no token becomes a Git option or revision.
public struct HistoryQuery: Sendable {
    public var arguments: [String] = []
    public var paths: [String] = []
    public var hash: String?
    public init(_ text: String) throws {
        guard text.utf8.count <= 4096, !text.utf8.contains(0) else { throw GitFailure("History queries must be under 4 KB without NUL bytes.") }
        var tokens: [String] = [], token = "", quoted = false, escaped = false
        for character in text {
            if escaped { token.append(character); escaped = false }
            else if character == "\\", quoted { escaped = true }
            else if character == "\"" { quoted.toggle() }
            else if character.isWhitespace && !quoted { if !token.isEmpty { tokens.append(token); token = "" } }
            else { token.append(character) }
        }
        guard !quoted, !escaped else { throw GitFailure("Close the quoted value in the history query.") }
        if !token.isEmpty { tokens.append(token) }
        var message: [String] = []
        for item in tokens {
            let pair = item.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let field = String(pair[0]).lowercased(), value = pair.count == 2 ? String(pair[1]) : ""
            guard pair.count == 2 && ["author", "committer", "after", "before", "path", "hash", "message"].contains(field) else { message.append(item); continue }
            guard !value.isEmpty else { throw GitFailure("Enter a value after \(field):.") }
            switch field {
            case "path":
                guard !value.hasPrefix("/"), !value.split(separator: "/").contains("..") else { throw GitFailure("Search for a repository-relative path.") }
                // GitProcess supplies --literal-pathspecs for log.
                paths.append(value)
            case "hash":
                guard hash == nil, (4...64).contains(value.count), value.allSatisfy(\.isHexDigit) else { throw GitFailure("Use one hexadecimal commit hash of 4–64 characters.") }
                hash = value.lowercased()
            case "message": message.append(value)
            case "after", "before":
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
                guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else { throw GitFailure("Use yyyy-MM-dd for \(field):.") }
                arguments.append((field == "after" ? "--since-as-filter=" : "--until=") + value + (field == "before" ? "T23:59:59Z" : "T00:00:00Z"))
            default: arguments.append("--\(field)=" + value)
            }
        }
        arguments = ["--regexp-ignore-case", "--fixed-strings"] + arguments
        if !message.isEmpty { arguments.append("--grep=" + message.joined(separator: " ")) }
    }
}
