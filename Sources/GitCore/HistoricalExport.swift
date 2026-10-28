import Darwin
import Foundation

public enum HistoricalExport {
    static func validatePath(_ path: String) throws {
        let parts = path.components(separatedBy: "/")
        guard !path.isEmpty, !path.utf8.contains(0), !path.hasPrefix("/"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) != ".git" }) else { throw GitFailure("Unsafe historical export path: \(path)") }
    }

    static func validateLink(_ file: HistoricalFile) throws -> String {
        guard let target = String(data: file.data, encoding: .utf8), !target.isEmpty, !target.hasPrefix("/"), !target.utf8.contains(0), target.utf8.count <= 4096 else { throw GitFailure("An exported link has an absolute or unsupported target: \(file.path)") }
        var parts = Array(file.path.split(separator: "/").dropLast().map(String.init))
        for part in target.components(separatedBy: "/") {
            if part == ".." { guard !parts.isEmpty else { throw GitFailure("An exported link would escape its destination: \(file.path)") }; parts.removeLast() }
            else if part != "." && !part.isEmpty { parts.append(part) }
        }
        if !parts.isEmpty { try validatePath(parts.joined(separator: "/")) }
        return target
    }

    public static func validate(_ snapshot: HistoricalSnapshot) throws {
        guard snapshot.files.count <= 10_000, snapshot.totalBytes <= 64 * 1024 * 1024 else { throw GitFailure("Invalid or oversized historical export.") }
        var names: Set<String> = []
        for file in snapshot.files {
            try validatePath(file.path)
            guard file.data.count <= 16 * 1024 * 1024, file.isRegular || file.isLink || file.isSubmodule,
                  names.insert(file.path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw GitFailure("Unsupported or duplicate historical export entry.") }
            if file.isLink { _ = try validateLink(file) }
        }
        let nonDirectories = Set(snapshot.files.filter { !$0.isSubmodule }.map(\.path))
        for file in snapshot.files {
            let parts = file.path.split(separator: "/")
            for length in 1..<parts.count where nonDirectories.contains(parts.prefix(length).joined(separator: "/")) { throw GitFailure("A file or link is an ancestor of another archive entry.") }
        }
    }

    public static func writeFile(_ file: HistoricalFile, to url: URL) throws {
        try validatePath(file.path)
        guard file.isRegular, file.data.count <= 16 * 1024 * 1024 else { throw GitFailure("Raw file export requires a regular file. Use ZIP for a symbolic link or directory.") }
        try installNewItem(at: url, directory: false) { temporary in
            try file.data.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: file.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: temporary.path)
        }
    }

    public static func writeFolder(_ snapshot: HistoricalSnapshot, to url: URL) throws {
        try validate(snapshot)
        try installNewItem(at: url, directory: true) { temporary in
            for file in snapshot.files where !file.isLink {
                let target = temporary.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: file.isSubmodule ? target : target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if file.isRegular {
                    try file.data.write(to: target, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: file.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: target.path)
                }
            }
            // Create links last so they can never become parent directories of a write.
            for file in snapshot.files where file.isLink {
                let target = temporary.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: try validateLink(file))
            }
        }
    }

    public static func writeZIP(_ snapshot: HistoricalSnapshot, to url: URL) throws {
        let data = try zipData(snapshot)
        try installNewItem(at: url, directory: false) { try data.write(to: $0, options: .withoutOverwriting) }
    }

    // ZIP32 store records avoid subprocess limits and export-ignore/export-subst filters.
    public static func zipData(_ snapshot: HistoricalSnapshot) throws -> Data {
        try validate(snapshot)
        var result = Data(), central = Data()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: snapshot.date)
        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let date = UInt16((year - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        for file in snapshot.files {
            let name = Data((file.path + (file.isSubmodule ? "/" : "")).utf8)
            guard name.count <= Int(UInt16.max) else { throw GitFailure("An archive filename is too long.") }
            let offset = UInt32(result.count), size = UInt32(file.data.count), crc = crc32(file.data)
            result.zip32(0x04034b50); result.zip16(20); result.zip16(0x800); result.zip16(0)
            result.zip16(time); result.zip16(date); result.zip32(crc); result.zip32(size); result.zip32(size)
            result.zip16(UInt16(name.count)); result.zip16(0); result.append(name); result.append(file.data)
            let mode: UInt32 = file.isSubmodule ? 0o40755 : file.isLink ? 0o120777 : file.mode == "100755" ? 0o100755 : 0o100644
            central.zip32(0x02014b50); central.zip16(0x0314); central.zip16(20); central.zip16(0x800); central.zip16(0)
            central.zip16(time); central.zip16(date); central.zip32(crc); central.zip32(size); central.zip32(size)
            central.zip16(UInt16(name.count)); central.zip16(0); central.zip16(0); central.zip16(0); central.zip16(0)
            central.zip32(mode << 16 | (file.isSubmodule ? 0x10 : 0)); central.zip32(offset); central.append(name)
        }
        let offset = UInt32(result.count); result.append(central)
        result.zip32(0x06054b50); result.zip16(0); result.zip16(0)
        result.zip16(UInt16(snapshot.files.count)); result.zip16(UInt16(snapshot.files.count))
        result.zip32(UInt32(central.count)); result.zip32(offset); result.zip16(0)
        return result
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        return crc
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }

    private static func installNewItem(at url: URL, directory: Bool, write: (URL) throws -> Void) throws {
        // Work inside a private sibling directory, then atomically refuse replacement.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let final = parent.appendingPathComponent(url.lastPathComponent)
        let staging = parent.appendingPathComponent(".gitpico-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let item = staging.appendingPathComponent("contents")
        if directory { try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try write(item)
        guard Darwin.renamex_np(item.path, final.path, UInt32(RENAME_EXCL)) == 0 else { throw GitFailure("Export could not create the destination. Choose a new name; existing items are never replaced.") }
    }
}

private extension Data {
    mutating func zip16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func zip32(_ value: UInt32) { zip16(UInt16(truncatingIfNeeded: value)); zip16(UInt16(truncatingIfNeeded: value >> 16)) }
}
