import Foundation
import Testing
@testable import GitCore

private func enableLFS(_ f: Fixture, hook: Bool = false) async throws {
    try await f.repo.applyLFSChange(try await f.repo.previewLFSChange(.enable(installHook: hook)))
}

@Test func lfsLocalActivationTrackingLiteralNamesAndRecoveryPreserveStaging() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let originalIndex = try await f.repo.submoduleAddIndex(), originalHead = try await f.repo.headPosition()
    try await enableLFS(f)
    #expect(try await f.repo.lfsState().enabled)
    try f.write("space [a] $(touch injected).bin", "binary bytes\n")
    try f.write(".gitattributes", "# Keep manual rules\n*.txt text\n")
    let plan = try await f.repo.previewLFSChange(.track("space [a] $(touch injected).bin", filename: true, source: ".gitattributes"))
    #expect(try String(contentsOf: f.url.appendingPathComponent(".gitattributes"), encoding: .utf8) == "# Keep manual rules\n*.txt text\n")
    try await f.repo.applyLFSChange(plan)
    let state = try await f.repo.lfsState()
    #expect(state.rules.count == 1)
    #expect(try await f.repo.submoduleAddIndex() == originalIndex)
    #expect(try await f.repo.headPosition() == originalHead)
    #expect(!FileManager.default.fileExists(atPath: f.url.appendingPathComponent("injected").path))
    let record = try #require(try await f.repo.lfsChangeHistory().first)
    try await f.repo.restoreLFSChange(record)
    #expect(try String(contentsOf: f.url.appendingPathComponent(".gitattributes"), encoding: .utf8) == "# Keep manual rules\n*.txt text\n")
    #expect(try String(contentsOf: f.url.appendingPathComponent("space [a] $(touch injected).bin"), encoding: .utf8) == "binary bytes\n")
}

@Test func lfsPatternRemovalNestedAttributesAndStaleChangesAreGuarded() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await enableLFS(f)
    try FileManager.default.createDirectory(at: f.url.appendingPathComponent("art"), withIntermediateDirectories: true)
    try await f.repo.applyLFSChange(try await f.repo.previewLFSChange(.track("*.psd", filename: false, source: "art/.gitattributes")))
    let rule = try #require(try await f.repo.lfsState().rules.first)
    #expect(rule.source == "art/.gitattributes")
    try await f.repo.applyLFSChange(try await f.repo.previewLFSChange(.untrack(rule.relativePattern, source: rule.source)))
    #expect(try await f.repo.lfsState().rules.isEmpty)
    let stale = try await f.repo.previewLFSChange(.track("*.bin", filename: false, source: ".gitattributes"))
    try f.write(".gitattributes", "# later manual edit\n")
    await #expect(throws: GitFailure.self) { try await f.repo.applyLFSChange(stale) }
    #expect(try String(contentsOf: f.url.appendingPathComponent(".gitattributes"), encoding: .utf8) == "# later manual edit\n")
    await #expect(throws: GitFailure.self) { try await f.repo.previewLFSChange(.track("--evil", filename: false, source: ".gitattributes")) }
    await #expect(throws: GitFailure.self) { try await f.repo.previewLFSChange(.track("*.bin\n*.txt", filename: false, source: ".gitattributes")) }
    await #expect(throws: GitFailure.self) { try await f.repo.previewLFSChange(.track("*.bin", filename: false, source: "../.gitattributes")) }
}

@Test func lfsHooksAreLocalExecutableAndCustomScriptsAreNeverReplaced() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let hooks = f.url.appendingPathComponent(".git/hooks"), hook = hooks.appendingPathComponent("pre-push")
    try await f.git(["config", "core.hooksPath", hooks.path])
    try await enableLFS(f, hook: true)
    let generated = try Data(contentsOf: hook)
    #expect(String(decoding: generated, as: UTF8.self).contains("git lfs pre-push"))
    #expect(FileManager.default.isExecutableFile(atPath: hook.path))
    let custom = generated + Data("\necho custom validation\n".utf8)
    try custom.write(to: hook)
    await #expect(throws: GitFailure.self) { try await f.repo.previewLFSChange(.enable(installHook: true)) }
    #expect(try Data(contentsOf: hook) == custom)
    try await enableLFS(f, hook: false)
    #expect(try Data(contentsOf: hook) == custom)
    try await f.repo.applyLFSChange(try await f.repo.previewLFSChange(.disable))
    #expect(try await f.repo.lfsState().enabled == false)
    #expect(try Data(contentsOf: hook) == custom)
    try await f.git(["config", "core.hooksPath", "/dev/null"])
    await #expect(throws: GitFailure.self) { try await f.repo.previewLFSChange(.enable(installHook: true)) }
}

@Test func lfsSettingRecoveryProtectsNewEditsLocksAndChangedHeads() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await enableLFS(f)
    try await f.repo.applyLFSChange(try await f.repo.previewLFSChange(.track("*.bin", filename: false, source: ".gitattributes")))
    var record = try #require(try await f.repo.lfsChangeHistory().first)
    let lock = f.url.appendingPathComponent(".gitattributes.lock")
    try Data("other owner".utf8).write(to: lock)
    await #expect(throws: GitFailure.self) { try await f.repo.restoreLFSChange(record) }
    #expect(try String(contentsOf: lock, encoding: .utf8) == "other owner")
    try FileManager.default.removeItem(at: lock)
    record = try #require(try await f.repo.lfsChangeHistory().first)
    try await f.repo.restoreLFSChange(record)
    try await f.repo.applyLFSChange(try await f.repo.previewLFSChange(.track("*.psd", filename: false, source: ".gitattributes")))
    record = try #require(try await f.repo.lfsChangeHistory().first)
    try f.write(".gitattributes", "manual changes\n")
    await #expect(throws: GitFailure.self) { try await f.repo.restoreLFSChange(record) }
    try await f.git(["commit", "--allow-empty", "-m", "New HEAD"])
    await #expect(throws: GitFailure.self) { try await f.repo.restoreLFSChange(record) }
}

@Test func lfsRealLocalObjectPushCloneFetchPullAndCheckoutKeepModifiedFiles() async throws {
    let f = try await Fixture.make()
    let bare = URL(fileURLWithPath: f.url.path + "-bare"), pointers = URL(fileURLWithPath: f.url.path + "-pointers"), full = URL(fileURLWithPath: f.url.path + "-full"), fetched = URL(fileURLWithPath: f.url.path + "-fetched")
    defer { f.clean(); for path in [bare,pointers,full,fetched] { try? FileManager.default.removeItem(at: path) } }
    try await enableLFS(f)
    try await f.repo.applyLFSChange(try await f.repo.previewLFSChange(.track("*.bin", filename: false, source: ".gitattributes")))
    let bytes = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) }); try bytes.write(to: f.url.appendingPathComponent("asset.bin"))
    try await f.git(["add", ".gitattributes", "asset.bin"]); try await f.git(["commit", "-m", "LFS data"])
    let pointer = try await f.git(["show", "HEAD:asset.bin"]).data
    #expect(String(decoding: pointer, as: UTF8.self).hasPrefix("version https://git-lfs.github.com/spec/v1"))
    _ = try await GitProcess.run(["init", "--bare", bare.path], at: f.url)
    try await f.git(["remote", "add", "origin", bare.path])
    _ = try await GitProcess.run(["symbolic-ref", "HEAD", "refs/heads/main"], at: bare)
    let pushPlan = try await f.repo.previewLFSTransfer(.push)
    #expect(pushPlan.endpoint.contains(bare.path))
    let pushed = try await f.repo.runLFSTransfer(pushPlan)
    #expect(pushed.succeeded)
    try await f.git(["push", "origin", "main"])
    let remoteObjects = bare.appendingPathComponent("lfs/objects")
    try FileManager.default.removeItem(at: remoteObjects)
    let repaired = try await f.repo.runLFSTransfer(try await f.repo.previewLFSTransfer(.push, allObjects: true))
    #expect(repaired.succeeded)
    let clone = try await GitRepository.create(at: pointers, source: bare.path, lfs: .pointersOnly)
    #expect(try Data(contentsOf: pointers.appendingPathComponent("asset.bin")) == pointer)
    _ = try await clone.runLFSTransfer(try await clone.previewLFSTransfer(.pull))
    #expect(try Data(contentsOf: pointers.appendingPathComponent("asset.bin")) == bytes)
    _ = try await GitRepository.create(at: full, source: bare.path, lfs: .download)
    #expect(try Data(contentsOf: full.appendingPathComponent("asset.bin")) == bytes)
    let cache = try await GitRepository.create(at: fetched, source: bare.path, lfs: .pointersOnly)
    _ = try await cache.runLFSTransfer(try await cache.previewLFSTransfer(.fetch))
    #expect(try Data(contentsOf: fetched.appendingPathComponent("asset.bin")) == pointer)
    _ = try await cache.runLFSTransfer(try await cache.previewLFSTransfer(.checkout))
    #expect(try Data(contentsOf: fetched.appendingPathComponent("asset.bin")) == bytes)
    let index = try await cache.submoduleAddIndex()
    try Data("new local work".utf8).write(to: fetched.appendingPathComponent("asset.bin"))
    _ = try await cache.runLFSTransfer(try await cache.previewLFSTransfer(.checkout))
    #expect(try Data(contentsOf: fetched.appendingPathComponent("asset.bin")) == Data("new local work".utf8))
    #expect(try await cache.submoduleAddIndex() == index)
    #expect(try await cache.lfsTransferHistory().count == 3)
}

@Test func lfsTransferRejectsChangedEndpointsAndReportsActualErrors() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try await enableLFS(f)
    try await f.git(["remote", "add", "origin", f.url.path + "-missing"])
    let plan = try await f.repo.previewLFSTransfer(.fetch)
    try await f.git(["config", "lfs.url", f.url.path + "-different"])
    await #expect(throws: GitFailure.self) { try await f.repo.runLFSTransfer(plan) }
    try await f.git(["config", "--unset", "lfs.url"])
    // A real missing object forces the native local transport to report an error.
    try f.write(".gitattributes", "*.bin filter=lfs diff=lfs merge=lfs -text\n")
    let missing = "version https://git-lfs.github.com/spec/v1\noid sha256:" + String(repeating: "a", count: 64) + "\nsize 100\n"
    try f.write("absent.bin", missing); try await f.git(["add", "absent.bin", ".gitattributes"]); try await f.git(["commit", "-m", "Missing LFS object"])
    await #expect(throws: GitFailure.self) { try await f.repo.runLFSTransfer(try await f.repo.previewLFSTransfer(.fetch)) }
    #expect(try await f.repo.lfsTransferHistory().first?.succeeded == false)
}

@Test func lfsExistingTrackedFilesConvertThroughReviewedIndexAndRecoverOriginalStaging() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    let data = Data(repeating: 73, count: 1024 * 1024)
    try data.write(to: f.url.appendingPathComponent("existing.bin")); try await f.git(["add", "existing.bin"]); try await f.git(["commit", "-m", "Normal Git binary"])
    try await enableLFS(f)
    try await f.repo.applyLFSChange(try await f.repo.previewLFSChange(.track("*.bin", filename: false, source: ".gitattributes")))
    try f.write("readme.txt", "unrelated staged work\n"); try await f.git(["add", "readme.txt"])
    let before = try await f.repo.submoduleAddIndex(), head = try await f.repo.headPosition()
    let plan = try await f.repo.previewLFSStaging()
    #expect(plan.paths == ["existing.bin"])
    #expect(try await f.repo.submoduleAddIndex() == before)
    #expect(try Data(contentsOf: f.url.appendingPathComponent("existing.bin")) == data)
    try await f.repo.applyLFSStaging(plan)
    let pointer = try await f.git(["show", ":existing.bin"]).text
    #expect(pointer.hasPrefix("version https://git-lfs.github.com/spec/v1"))
    #expect(try await f.git(["show", ":readme.txt"]).text == "unrelated staged work\n")
    #expect(try Data(contentsOf: f.url.appendingPathComponent("existing.bin")) == data)
    #expect(try await f.repo.headPosition() == head)
    let recovery = try #require(try await f.repo.lfsChangeHistory().first)
    try await f.repo.restoreLFSChange(recovery)
    #expect(try await f.repo.submoduleAddIndex() == before)
}

@Test func lfsConversionRejectsNewFileContentsAttributesAndConcurrentStaging() async throws {
    let f = try await Fixture.make(); defer { f.clean() }
    try f.write("existing.bin", "normal bytes\n"); try await f.git(["add", "existing.bin"]); try await f.git(["commit", "-m", "Normal file"])
    try await enableLFS(f)
    try await f.repo.applyLFSChange(try await f.repo.previewLFSChange(.track("*.bin", filename: false, source: ".gitattributes")))
    var plan = try await f.repo.previewLFSStaging(paths: ["existing.bin"])
    let index = try await f.repo.submoduleAddIndex()
    try f.write("existing.bin", "new edits\n")
    await #expect(throws: GitFailure.self) { try await f.repo.applyLFSStaging(plan) }
    #expect(try await f.repo.submoduleAddIndex() == index)
    plan = try await f.repo.previewLFSStaging(paths: ["existing.bin"])
    try f.write(".gitattributes", "*.bin -filter\n")
    await #expect(throws: GitFailure.self) { try await f.repo.applyLFSStaging(plan) }
    #expect(try await f.repo.submoduleAddIndex() == index)
    try f.write(".gitattributes", "*.bin filter=lfs diff=lfs merge=lfs -text\n")
    plan = try await f.repo.previewLFSStaging(paths: ["existing.bin"])
    try f.write("readme.txt", "new staging\n"); try await f.git(["add", "readme.txt"])
    await #expect(throws: GitFailure.self) { try await f.repo.applyLFSStaging(plan) }
    #expect(try await f.git(["show", ":readme.txt"]).text == "new staging\n")
    try await f.repo.applyLFSChange(try await f.repo.previewLFSChange(.disable))
    await #expect(throws: GitFailure.self) { try await f.repo.previewLFSStaging(paths: ["existing.bin"]) }
    try await enableLFS(f)
    try await f.git(["update-index", "--split-index"])
    await #expect(throws: GitFailure.self) { try await f.repo.previewLFSStaging(paths: ["existing.bin"]) }
    try await f.git(["update-index", "--no-split-index"])
    try await f.git(["update-index", "--assume-unchanged", "existing.bin"])
    await #expect(throws: GitFailure.self) { try await f.repo.previewLFSStaging(paths: ["existing.bin"]) }
}
