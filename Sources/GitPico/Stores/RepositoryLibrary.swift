import Foundation
import GitCore
import Observation

struct SavedRepository: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var path: String
    var name: String
    var group: UUID?
    var favorite = false
    var lastOpened: Date?
}
struct RepositoryGroup: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var parent: UUID?
}
struct RepositoryLibraryDocument: Codable, Equatable, Sendable {
    var version = 1
    var repositories: [SavedRepository] = []
    var groups: [RepositoryGroup] = []
    var recent: [UUID] = []
}
enum RepositoryLibraryFilter: Hashable {
    case all, favorites, recent, ungrouped, group(UUID)
}
struct RepositoryLibraryDrop: Codable, Sendable {
    let session: UUID
    let repositories: [UUID]
}

@MainActor @Observable
final class RepositoryLibrary {
    private(set) var document = RepositoryLibraryDocument()
    private(set) var error: String?
    private(set) var session = UUID()
    @ObservationIgnored let file: URL
    @ObservationIgnored private var diskData: Data?
    @ObservationIgnored private var loaded = false
    private var legacy: [String]

    init(file: URL? = nil, legacy: [String]? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GitPico/repository-library.json")
        self.legacy = legacy ?? RepositoryHistory.load()
        reload()
    }
    var recentPaths: [String] { document.recent.compactMap { id in document.repositories.first { $0.id == id }?.path } }
    func displayName(for path: String) -> String { document.repositories.first { $0.path == path }?.name ?? URL(fileURLWithPath: path).lastPathComponent }
    func reload() {
        do {
            let data = try readDisk()
            var value = try data.map { try JSONDecoder().decode(RepositoryLibraryDocument.self, from: $0) } ?? RepositoryLibraryDocument()
            if data == nil {
                for path in legacy.prefix(12) where path.hasPrefix("/") && !path.utf8.contains(0) {
                    let path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
                    guard !value.repositories.contains(where: { $0.path == path }) else { continue }
                    let record = SavedRepository(id: UUID(), path: path, name: defaultName(URL(fileURLWithPath: path)))
                    value.repositories.append(record); value.recent.append(record.id)
                }
            }
            try validate(value)
            document = value; diskData = data; loaded = true; error = nil; session = UUID()
        } catch { self.error = "Repository library could not be loaded: " + error.localizedDescription; loaded = false }
    }
    private func readDisk() throws -> Data? {
        for current in [file, file.deletingLastPathComponent()] {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw GitFailure("Library storage contains a symbolic link.") }
                if current == file {
                    guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 4 * 1024 * 1024 else { throw GitFailure("Invalid or oversized library file.") }
                }
            } catch {
                let value = error as NSError
                guard value.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(value.code) else { throw error }
            }
        }
        return FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
    }
    private func validate(_ value: RepositoryLibraryDocument) throws {
        guard value.version == 1, value.repositories.count <= 5000, value.groups.count <= 500,
              Set(value.repositories.map(\.id)).count == value.repositories.count,
              Set(value.repositories.map(\.path)).count == value.repositories.count,
              Set(value.groups.map(\.id)).count == value.groups.count,
              Set(value.recent).count == value.recent.count, value.recent.count <= 12 else { throw GitFailure("Unsupported or invalid repository library.") }
        for record in value.repositories {
            _ = try validName(record.name)
            guard record.path.hasPrefix("/"), !record.path.utf8.contains(0), record.path.utf8.count <= 4096,
                  record.group == nil || value.groups.contains(where: { $0.id == record.group }) else { throw GitFailure("Invalid repository path or group.") }
        }
        for group in value.groups {
            _ = try validName(group.name)
            var seen: Set<UUID> = [group.id], parent = group.parent
            while let id = parent {
                guard seen.insert(id).inserted, let node = value.groups.first(where: { $0.id == id }) else { throw GitFailure("Repository groups contain a cycle or missing parent.") }
                parent = node.parent
            }
        }
        guard value.recent.allSatisfy({ id in value.repositories.contains { $0.id == id } }) else { throw GitFailure("Invalid recent repository entry.") }
    }
    private func validName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 160, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw GitFailure("Enter a name of 1–160 characters without control characters.") }
        return value
    }
    private func update(_ action: (inout RepositoryLibraryDocument) throws -> Void) throws {
        do {
            guard loaded else { throw GitFailure("Reload the library after fixing its storage error. The existing file was kept.") }
            var value = document; try action(&value); try validate(value)
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lock = URL(fileURLWithPath: file.path + ".lock")
            do { try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false) }
            catch { throw GitFailure("The repository library is locked by another writer. Retry after it finishes.") }
            defer { try? FileManager.default.removeItem(at: lock) }
            guard try readDisk() == diskData else { throw GitFailure("The library changed outside this window. Reload it before editing.") }
            let data = try JSONEncoder().encode(value)
            guard data.count <= 4 * 1024 * 1024 else { throw GitFailure("The library exceeds its 4 MB storage limit. Remove unused registrations first.") }
            try data.write(to: file, options: .atomic)
            document = value; diskData = data; error = nil
        } catch { self.error = error.localizedDescription; throw error }
    }
    private func defaultName(_ url: URL) -> String {
        let value = String(String.UnicodeScalarView(url.lastPathComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Repository" : String(value.prefix(160))
    }
    @discardableResult func register(_ url: URL) throws -> UUID { try recordOpened(url, rememberRecent: false) }
    @discardableResult func recordOpened(_ url: URL, at date: Date = Date(), rememberRecent: Bool = true) throws -> UUID {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var result = UUID()
        try update { value in
            if let index = value.repositories.firstIndex(where: { $0.path == path }) {
                result = value.repositories[index].id; if rememberRecent { value.repositories[index].lastOpened = date }
            } else {
                value.repositories.append(SavedRepository(id: result, path: path, name: defaultName(url), lastOpened: rememberRecent ? date : nil))
            }
            if rememberRecent { value.recent.removeAll { $0 == result }; value.recent.insert(result, at: 0); value.recent = Array(value.recent.prefix(12)) }
        }
        return result
    }
    func rename(_ ids: Set<UUID>, to name: String) throws {
        let name = try validName(name)
        try update { value in
            guard ids.count == 1, let index = value.repositories.firstIndex(where: { ids.contains($0.id) }) else { throw GitFailure("Select one saved repository to rename.") }
            value.repositories[index].name = name
        }
    }
    func setFavorite(_ ids: Set<UUID>, _ favorite: Bool) throws {
        try update { value in
            guard !ids.isEmpty, ids.isSubset(of: Set(value.repositories.map(\.id))) else { throw GitFailure("The repository selection changed.") }
            for index in value.repositories.indices where ids.contains(value.repositories[index].id) { value.repositories[index].favorite = favorite }
        }
    }
    func remove(_ ids: Set<UUID>) throws {
        try update { value in
            value.repositories.removeAll { ids.contains($0.id) }; value.recent.removeAll { ids.contains($0) }
        }
    }
    @discardableResult func createGroup(_ name: String, parent: UUID? = nil) throws -> UUID {
        let name = try validName(name), id = UUID()
        try update { $0.groups.append(RepositoryGroup(id: id, name: name, parent: parent)) }
        return id
    }
    func renameGroup(_ id: UUID, _ name: String) throws {
        let name = try validName(name)
        try update { value in
            guard let index = value.groups.firstIndex(where: { $0.id == id }) else { throw GitFailure("The group no longer exists.") }
            value.groups[index].name = name
        }
    }
    func moveGroup(_ id: UUID, parent: UUID?) throws {
        try update { value in
            guard let index = value.groups.firstIndex(where: { $0.id == id }) else { throw GitFailure("The group no longer exists.") }
            value.groups[index].parent = parent
        }
    }
    func removeGroup(_ id: UUID) throws {
        try update { value in
            guard let group = value.groups.first(where: { $0.id == id }) else { throw GitFailure("The group no longer exists.") }
            for index in value.repositories.indices where value.repositories[index].group == id { value.repositories[index].group = group.parent }
            for index in value.groups.indices where value.groups[index].parent == id { value.groups[index].parent = group.parent }
            value.groups.removeAll { $0.id == id }
        }
    }
    func move(_ ids: Set<UUID>, to group: UUID?, before: UUID? = nil) throws {
        try update { value in
            guard !ids.isEmpty, ids.isSubset(of: Set(value.repositories.map(\.id))), group == nil || value.groups.contains(where: { $0.id == group }) else { throw GitFailure("The repository selection or destination changed.") }
            guard before == nil || (!ids.contains(before!) && value.repositories.contains(where: { $0.id == before && $0.group == group })) else { throw GitFailure("Choose a different repository as the insertion point.") }
            var moved = value.repositories.filter { ids.contains($0.id) }
            for index in moved.indices { moved[index].group = group }
            value.repositories.removeAll { ids.contains($0.id) }
            let index = before.flatMap { id in value.repositories.firstIndex { $0.id == id } } ?? value.repositories.endIndex
            value.repositories.insert(contentsOf: moved, at: index)
        }
    }
    func acceptDrop(_ tokens: [RepositoryLibraryDrop], to group: UUID?, before: UUID? = nil) -> Bool {
        guard !tokens.isEmpty, tokens.allSatisfy({ $0.session == session && !$0.repositories.isEmpty && $0.repositories.count <= 5000 }) else { return false }
        do { try move(Set(tokens.flatMap(\.repositories)), to: group, before: before); return true } catch { return false }
    }
    func sortContents(of group: UUID?) throws {
        try update { value in
            let repositoryIndices = value.repositories.indices.filter { value.repositories[$0].group == group }
            let repositories = repositoryIndices.map { value.repositories[$0] }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for (index, repository) in zip(repositoryIndices, repositories) { value.repositories[index] = repository }
            let groupIndices = value.groups.indices.filter { value.groups[$0].parent == group }
            let groups = groupIndices.map { value.groups[$0] }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for (index, entry) in zip(groupIndices, groups) { value.groups[index] = entry }
        }
    }
    func relocate(_ id: UUID, to url: URL) throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        try update { value in
            guard let index = value.repositories.firstIndex(where: { $0.id == id }), !value.repositories.contains(where: { $0.id != id && $0.path == path }) else { throw GitFailure("The repository is missing or this location is already registered.") }
            value.repositories[index].path = path
        }
    }
    func relocatePrefix(from oldRoot: String, to newRoot: String) throws {
        try update { value in
            for index in value.repositories.indices {
                let path = value.repositories[index].path
                if path == oldRoot || path.hasPrefix(oldRoot + "/") { value.repositories[index].path = newRoot + path.dropFirst(oldRoot.count) }
            }
            guard Set(value.repositories.map(\.path)).count == value.repositories.count else { throw GitFailure("A migrated location is already registered under a different saved repository.") }
        }
    }
    func breadcrumb(_ id: UUID?) -> String {
        guard let id, let group = document.groups.first(where: { $0.id == id }) else { return "" }
        let prefix = breadcrumb(group.parent)
        return prefix.isEmpty ? group.name : prefix + " / " + group.name
    }
    var orderedGroups: [RepositoryGroup] {
        func children(_ parent: UUID?) -> [RepositoryGroup] { document.groups.filter { $0.parent == parent }.flatMap { [$0] + children($0.id) } }
        return children(nil)
    }
    func matches(query: String = "", filter: RepositoryLibraryFilter = .all, ranked: Bool = false) -> [SavedRepository] {
        func folded(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        let query = folded(query.trimmingCharacters(in: .whitespacesAndNewlines)), terms = query.split(whereSeparator: \.isWhitespace)
        let values = document.repositories.filter { record in
            let included: Bool
            switch filter {
            case .all: included = true
            case .favorites: included = record.favorite
            case .recent: included = document.recent.contains(record.id)
            case .ungrouped: included = record.group == nil
            case .group(let id):
                var group = record.group; var found = false
                while let current = group { if current == id { found = true; break }; group = document.groups.first { $0.id == current }?.parent }
                included = found
            }
            let text = folded(record.name + " " + record.path + " " + breadcrumb(record.group))
            return included && terms.allSatisfy { text.contains($0) }
        }
        func rank(_ entry: SavedRepository) -> Int {
            let name = folded(entry.name)
            if query.isEmpty { return 0 }
            if name == query { return 0 }; if name.hasPrefix(query) { return 1 }; if name.contains(query) { return 2 }; return 3
        }
        guard ranked || filter == .recent else { return values }
        return values.sorted { left, right in
            if ranked && rank(left) != rank(right) { return rank(left) < rank(right) }
            if ranked && left.favorite != right.favorite { return left.favorite }
            let l = document.recent.firstIndex(of: left.id) ?? Int.max, r = document.recent.firstIndex(of: right.id) ?? Int.max
            if l != r { return l < r }
            return left.name == right.name ? left.path < right.path : left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}
