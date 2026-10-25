import Foundation

extension GitRepository {
    func writeExtensionRecord<T: Encodable>(_ value: T, name: String) async throws {
        let file = try await managementURL(name)
        try checkManagementAncestors(file)
        let data = try JSONEncoder().encode(value)
        guard data.count <= 128 * 1024 * 1024 else { throw GitFailure("Extension recovery metadata exceeds 128 MB.") }
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func readExtensionRecord<T: Decodable>(_ type: T.Type, name: String) async throws -> T? {
        let file = try await managementURL(name)
        try checkManagementAncestors(file)
        guard let attributes = try localAttributes(file) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular, ((attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max) <= 128 * 1024 * 1024 else { throw GitFailure("Invalid extension recovery metadata or file size.") }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }
}
