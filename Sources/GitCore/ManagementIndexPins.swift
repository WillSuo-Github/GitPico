import Foundation

extension GitRepository {
    // Pin every indexed object, including unmerged stages and intent-to-add entries.
    // A recovery tree cannot represent all conflict stages, but direct object refs can.
    func pinManagementIndex(_ data: Data?, id: UUID, side: String) async throws {
        guard let data else { return }
        let scratch = try makeLocalScratch(); defer { try? FileManager.default.removeItem(at: scratch) }
        let index = try await scratchIndex(data, in: scratch)
        let entries = try await GitProcess.run(["ls-files", "--stage", "-z"], at: root, indexFile: index).data.split(separator: 0)
        var objects = Set<String>()
        for entry in entries {
            guard let tab = entry.firstIndex(of: 9) else { throw GitFailure("Invalid indexed object record.") }
            let fields = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            guard fields.count == 3 else { throw GitFailure("Invalid indexed object record.") }
            if fields[0] != "160000", fields[1].contains(where: { $0 != "0" }) { objects.insert(String(fields[1])) }
        }
        guard objects.count <= 100_000 else { throw GitFailure("Management recovery supports up to 100,000 indexed objects.") }
        let commands = objects.sorted().enumerated().map { "update refs/gitpico/management-objects/\(id.uuidString.lowercased())/\(side)-\($0.offset) \($0.element)\n" }.joined()
        if !commands.isEmpty { _ = try await GitProcess.run(["update-ref", "--stdin"], at: root, input: Data(commands.utf8)) }
    }
}
