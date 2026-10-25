import Foundation

enum RepositoryHistory {
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitPico", isDirectory: true)
            .appendingPathComponent("recent-repositories.json")
    }

    static func load() -> [String] {
        guard let data = try? Data(contentsOf: file), let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Array(paths.prefix(12))
    }

    static func save(_ paths: [String]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Array(paths.prefix(12)))
        try data.write(to: file, options: .atomic)
    }
}
