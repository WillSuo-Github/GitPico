import Foundation
import Testing
@testable import GitCore

@Test func historicalRawExportPreservesBinaryEmptyExecutableAndLiteralNames() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let name = "folder/:(glob)* 中文\nfile.bin", bytes = Data([0, 255, 128, 10, 13, 0])
    try FileManager.default.createDirectory(at: f.url.appendingPathComponent("folder"), withIntermediateDirectories: true)
    try bytes.write(to: f.url.appendingPathComponent(name)); try f.write("empty", "")
    try f.write("run.sh", "#!/bin/sh\nprintf 'ok'\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.url.appendingPathComponent("run.sh").path)
    try await f.git(["add", "."]); try await f.git(["commit", "-m", "Export files"])
    let snapshot = try await f.repo.historicalSnapshot(revision: "HEAD", paths: [name, "empty", "run.sh"])
    #expect(snapshot.files.count == 3)
    let directory = f.url.appendingPathComponent("exports")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for file in snapshot.files { try HistoricalExport.writeFile(file, to: directory.appendingPathComponent((file.path as NSString).lastPathComponent)) }
    #expect(try Data(contentsOf: directory.appendingPathComponent((name as NSString).lastPathComponent)) == bytes)
    #expect(try Data(contentsOf: directory.appendingPathComponent("empty")).isEmpty)
    #expect((try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("run.sh").path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
}

@Test func historicalRestorePreservesStagingAndCanRecoverAfterRestart() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let old = try await f.repo.historicalSnapshot(revision: "HEAD", paths: ["readme.txt"])
    try f.write("readme.txt", "new committed\n"); try await f.git(["add", "."]); try await f.git(["commit", "-m", "New"])
    try f.write("readme.txt", "staged\n"); try await f.git(["add", "."]); try f.write("readme.txt", "later editing\n")
    let head = try await f.repo.headPosition()
    let plan = try await f.repo.previewHistoricalRestore(old)
    let backup = try await f.repo.applyLocalChange(plan)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "original\n")
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged\n")
    #expect(try await f.repo.headPosition() == head)
    let reopened = try await GitRepository.open(f.url)
    try await reopened.restoreLocalChanges(backup.id)
    #expect(try String(contentsOf: f.url.appendingPathComponent("readme.txt"), encoding: .utf8) == "later editing\n")
    #expect(try await f.git(["show", ":readme.txt"]).text == "staged\n")
}

@Test func historicalRestoreRenamedDestinationBinaryModeAndBothTarget() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let bytes = Data([0, 255, 10, 13, 128])
    try bytes.write(to: f.url.appendingPathComponent("readme.txt"))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.url.appendingPathComponent("readme.txt").path)
    try await f.git(["add", "."]); try await f.git(["commit", "-m", "Binary executable"])
    let historical = try await f.repo.historicalSnapshot(revision: "HEAD", paths: ["readme.txt"])
    try await f.git(["mv", "readme.txt", "renamed.bin"]); try f.write("renamed.bin", "current\n"); try await f.git(["add", "."]); try await f.git(["commit", "-m", "Rename"])
    let plan = try await f.repo.previewHistoricalRestore(historical, destination: "renamed.bin", target: .both)
    let backup = try await f.repo.applyLocalChange(plan)
    #expect(try Data(contentsOf: f.url.appendingPathComponent("renamed.bin")) == bytes)
    #expect(try await f.git(["show", ":renamed.bin"]).data == bytes)
    #expect(try await f.git(["ls-files", "--stage"]).text.hasPrefix("100755"))
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("readme.txt").path))
    try await f.repo.restoreLocalChanges(backup.id)
    #expect(try await f.repo.snapshot().changes.isEmpty)
}

@Test func historicalRestoreDeletedFileAndNewTargetPath() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let old = try await f.repo.historicalSnapshot(revision: "HEAD", paths: ["readme.txt"])
    try await f.git(["rm", "readme.txt"]); try await f.git(["commit", "-m", "Delete"])
    await #expect(throws: GitFailure.self) { try await f.repo.historicalSnapshot(revision: "HEAD", paths: ["readme.txt"]) }
    let deletionParent = try await f.repo.historicalSnapshot(revision: "HEAD^", paths: ["readme.txt"])
    #expect(deletionParent.files.first?.data == old.files.first?.data)
    let plan = try await f.repo.previewHistoricalRestore(old, destination: "nested/restored.txt", target: .both)
    try await f.repo.applyLocalChange(plan)
    #expect(try await f.git(["show", ":nested/restored.txt"]).text == "original\n")
}

@Test func historicalRestoreRejectsStalePreviewUntrackedIgnoredAndSymlinkTargets() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let old = try await f.repo.historicalSnapshot(revision: "HEAD", paths: ["readme.txt"])
    try f.write("readme.txt", "before\n")
    let plan = try await f.repo.previewHistoricalRestore(old)
    try f.write("readme.txt", "external edit\n")
    await #expect(throws: GitFailure.self) { try await f.repo.applyLocalChange(plan) }
    for path in ["new", "ignored"] {
        try f.write(path, "keep\n"); try f.write(".gitignore", "ignored\n")
        await #expect(throws: GitFailure.self) { try await f.repo.previewHistoricalRestore(old, destination: path) }
        #expect(try String(contentsOf: f.url.appendingPathComponent(path), encoding: .utf8) == "keep\n")
    }
    try FileManager.default.createSymbolicLink(at: f.url.appendingPathComponent("link"), withDestinationURL: f.url.appendingPathComponent("readme.txt"))
    await #expect(throws: GitFailure.self) { try await f.repo.previewHistoricalRestore(old, destination: "link") }
    for path in ["../outside", ".git/config", "/tmp/outside"] {
        await #expect(throws: GitFailure.self) { try await f.repo.previewHistoricalRestore(old, destination: path) }
    }
}

@Test func historicalSnapshotStaysOnImmutableRevisionAndRejectsMissingSelection() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let old = try await f.repo.historicalSnapshot(revision: "main", paths: ["readme.txt"])
    try f.write("readme.txt", "new main\n"); try await f.git(["add", "."]); try await f.git(["commit", "-m", "Advance"])
    #expect(old.files.first?.data == Data("original\n".utf8))
    #expect(old.revision != (try await f.repo.headPosition()).hash)
    await #expect(throws: GitFailure.self) { try await f.repo.historicalSnapshot(revision: "HEAD", paths: ["readme.txt", "absent"]) }
    await #expect(throws: GitFailure.self) { try await f.repo.historicalSnapshot(revision: "--bad", paths: ["readme.txt"]) }
}

@Test func historicalFolderExportKeepsExactObjectsDespiteArchiveAttributes() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("folder/a", "$Format:%H$\r\nno newline"); try f.write("folder/empty", "")
    try f.write(".gitattributes", "folder/a export-subst\nfolder/empty export-ignore\n")
    try await f.git(["add", "."]); try await f.git(["commit", "-m", "Attributes"])
    let snapshot = try await f.repo.historicalSnapshot(revision: "HEAD", paths: ["folder"])
    #expect(snapshot.files.count == 2)
    let destination = f.url.appendingPathComponent("output")
    try HistoricalExport.writeFolder(snapshot, to: destination)
    #expect(try Data(contentsOf: destination.appendingPathComponent("folder/a")) == Data("$Format:%H$\r\nno newline".utf8))
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("folder/empty").path))
    #expect(throws: GitFailure.self) { try HistoricalExport.writeFolder(snapshot, to: destination) }
    #expect(throws: GitFailure.self) { try HistoricalExport.writeFile(try #require(snapshot.files.first), to: destination.appendingPathComponent("folder/a")) }
}

@Test func historicalZIPIsAcceptedByIndependentUnzipWithModesAndBytes() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("folder/中文 [1]\nfile.txt", "unicode\r\nno newline"); try f.write("run", "#!/bin/sh\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.url.appendingPathComponent("run").path)
    try Data([0, 255, 128, 10, 0]).write(to: f.url.appendingPathComponent("binary"))
    try f.write("empty", ""); try FileManager.default.createSymbolicLink(atPath: f.url.appendingPathComponent("folder/link").path, withDestinationPath: "../binary")
    try await f.git(["add", "."]); try await f.git(["commit", "-m", "ZIP"])
    let snapshot = try await f.repo.historicalSnapshot(revision: "HEAD")
    let zip = f.url.appendingPathComponent("export.zip"), extracted = f.url.appendingPathComponent("extracted")
    try HistoricalExport.writeZIP(snapshot, to: zip)
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-qq", "-^", zip.path, "-d", extracted.path]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
    for file in snapshot.files where file.isRegular { #expect(try Data(contentsOf: extracted.appendingPathComponent(file.path)) == file.data) }
    #expect((try FileManager.default.attributesOfItem(atPath: extracted.appendingPathComponent("run").path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: extracted.appendingPathComponent("folder/link").path) == "../binary")
    #expect(throws: GitFailure.self) { try HistoricalExport.writeZIP(snapshot, to: zip) }
}

@Test func historicalExportRejectsEscapingSymlinksAndDeclaresSubmoduleBoundary() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try FileManager.default.createSymbolicLink(atPath: f.url.appendingPathComponent("escape").path, withDestinationPath: "../outside")
    try await f.git(["add", "."]); try await f.git(["commit", "-m", "Link"])
    let unsafe = try await f.repo.historicalSnapshot(revision: "HEAD", paths: ["escape"])
    #expect(throws: GitFailure.self) { try HistoricalExport.zipData(unsafe) }
    await #expect(throws: GitFailure.self) { try await f.repo.previewHistoricalRestore(unsafe) }
    let hash = try #require(try await f.repo.headPosition().hash)
    try await f.git(["update-index", "--add", "--cacheinfo", "160000," + hash + ",module"]); try await f.git(["commit", "-m", "Gitlink"])
    let submodule = try await f.repo.historicalSnapshot(revision: "HEAD", paths: ["module"])
    #expect(!submodule.warnings.isEmpty)
    let destination = f.url.appendingPathComponent("modules")
    try HistoricalExport.writeFolder(submodule, to: destination)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("module").path).isEmpty)
    await #expect(throws: GitFailure.self) { try await f.repo.previewHistoricalRestore(submodule) }
}

@Test func historicalBatchCanReadMoreThanDefaultProcessLimitAndBoundsOversizedFiles() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let bytes = Data(repeating: 0x61, count: 9 * 1024 * 1024)
    try bytes.write(to: f.url.appendingPathComponent("large-a"))
    try Data(repeating: 0x62, count: bytes.count).write(to: f.url.appendingPathComponent("large-b"))
    try await f.git(["add", "."]); try await f.git(["commit", "-m", "Large selection"])
    let snapshot = try await f.repo.historicalSnapshot(revision: "HEAD", paths: ["large-a", "large-b"])
    #expect(snapshot.totalBytes == 18 * 1024 * 1024)
    #expect(snapshot.files.first { $0.path == "large-a" }?.data == bytes)
    try Data(repeating: 0x63, count: 16 * 1024 * 1024 + 1).write(to: f.url.appendingPathComponent("oversized"))
    try await f.git(["add", "oversized"]); try await f.git(["commit", "-m", "Too large"])
    await #expect(throws: GitFailure.self) { try await f.repo.historicalSnapshot(revision: "HEAD", paths: ["oversized"]) }
}

@Test func historicalRestoreUsesWorktreeConversionWhileRawExportDoesNot() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let old = try await f.repo.historicalSnapshot(revision: "HEAD", paths: ["readme.txt"])
    try f.write(".gitattributes", "*.txt text eol=crlf\n")
    try f.write("readme.txt", "current\r\n")
    try await f.git(["add", "."]); try await f.git(["commit", "-m", "CRLF settings"])
    let plan = try await f.repo.previewHistoricalRestore(old, target: .both)
    try await f.repo.applyLocalChange(plan)
    #expect(try Data(contentsOf: f.url.appendingPathComponent("readme.txt")) == Data("original\r\n".utf8))
    #expect(try await f.git(["show", ":readme.txt"]).data == Data("original\n".utf8))
    #expect(old.files.first?.data == Data("original\n".utf8))
}

@Test func historicalEmptyProjectCanExportFolderAndValidEmptyZIP() async throws {
    let f = try await Fixture.make(initialCommit: false); defer { f.clean() }
    try await f.git(["commit", "--allow-empty", "-m", "Empty"])
    let snapshot = try await f.repo.historicalSnapshot(revision: "HEAD")
    #expect(snapshot.files.isEmpty)
    let destination = f.url.appendingPathComponent("empty-export"), zip = f.url.appendingPathComponent("empty.zip")
    try HistoricalExport.writeFolder(snapshot, to: destination)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    try HistoricalExport.writeZIP(snapshot, to: zip)
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None and z.namelist()==[]", zip.path]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
}
