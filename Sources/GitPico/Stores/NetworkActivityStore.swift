import CryptoKit
import Darwin
import Foundation
import GitCore
import Observation

struct NetworkActivityRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let command: String
    let repository: String
    var repositoryPath: String? = nil
    let started: Date
    var finished: Date?
    var phase: GitNetworkEvent.Phase
    var output: String
    var progress: Double? {
        guard phase == .running, let regex = try? NSRegularExpression(pattern: "([0-9]{1,3})%"), let match = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).last, let range = Range(match.range(at: 1), in: output), let value = Double(output[range]), value <= 100 else { return nil }
        return value / 100
    }
}
private final class NetworkHistoryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.willsuo.GitPico.network-history")
    private var revision: UInt64 = 0
    let file: URL
    init(file: URL) { self.file = file }
    func save(_ records: [NetworkActivityRecord], revision: UInt64) throws {
        try queue.sync {
            guard revision >= self.revision else { return }
            var retained = records
            var data = try JSONEncoder().encode(retained)
            while data.count >= 8 * 1024 * 1024, !retained.isEmpty {
                retained.removeLast(); data = try JSONEncoder().encode(retained)
            }
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard (try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType) == .typeDirectory else { throw appFailure("Activity storage is not a regular directory.") }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path), attributes[.type] as? FileAttributeType != .typeRegular { throw appFailure("Activity storage is not a regular file.") }
            let temporary = directory.appendingPathComponent("activity-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]), rename(temporary.path, file.path) == 0 else { throw appFailure("Could not save network activity history.") }
            self.revision = revision
        }
    }
}
@MainActor @Observable final class NetworkActivityStore {
    private(set) var records: [NetworkActivityRecord] = []
    var storageError: String?
    @ObservationIgnored private var cancellations: [UUID: GitNetworkCancellation] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored let file: URL
    @ObservationIgnored private let writer: NetworkHistoryWriter
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var backgroundReservation: UUID?
    var runningCount: Int { records.filter { $0.phase == .running }.count }
    deinit { saveTask?.cancel() }
    init(directory: URL) {
        file = directory.appendingPathComponent("network-activity.json")
        writer = NetworkHistoryWriter(file: file)
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 8 * 1024 * 1024 else { throw appFailure("Network activity storage is invalid.") }
                records = Array(try JSONDecoder().decode([NetworkActivityRecord].self, from: Data(contentsOf: file)).prefix(100))
                for index in records.indices {
                    records[index].output = GitLogRedaction.clean(records[index].output)
                    if records[index].phase == .running {
                        records[index].phase = .failed; records[index].finished = Date()
                        records[index].output += String(localized: "\nGitPico was closed before completion was recorded. Inspect the repository and remote before retrying.")
                    }
                }
            }
        } catch { storageError = error.localizedDescription }
    }
    func receive(_ event: GitNetworkEvent) {
        let output = GitLogRedaction.clean(String(decoding: Data(event.output.utf8.suffix(32_768)), as: UTF8.self))
        let isNew = !records.contains { $0.id == event.id }
        if let index = records.firstIndex(where: { $0.id == event.id }) {
            guard records[index].phase == .running else { return }
            records[index].phase = event.phase; records[index].output = output
            if event.phase != .running { records[index].finished = Date() }
        } else {
            records.insert(NetworkActivityRecord(id: event.id, command: event.command, repository: event.repository, repositoryPath: event.repositoryPath, started: event.started, finished: event.phase == .running ? nil : Date(), phase: event.phase, output: output), at: 0)
        }
        if event.phase == .running { cancellations[event.id] = event.cancellation }
        else { cancellations.removeValue(forKey: event.id) }
        if records.count > 100, let oldest = records.lastIndex(where: { $0.phase != .running }) { records.remove(at: oldest) }
        if isNew || event.phase != .running { save() }
    }
    func cancel(_ id: UUID) { cancellations[id]?.cancel() }
    func reserveBackgroundFetch() -> UUID? {
        guard backgroundReservation == nil, runningCount == 0 else { return nil }
        let token = UUID(); backgroundReservation = token; return token
    }
    func releaseBackgroundFetch(_ token: UUID) { if backgroundReservation == token { backgroundReservation = nil } }
    func flush() {
        saveTask?.cancel(); revision += 1
        do { try writer.save(records, revision: revision); storageError = nil }
        catch { storageError = error.localizedDescription }
    }
    func clearCompleted() { records.removeAll { $0.phase != .running }; save() }
    private func save() {
        saveTask?.cancel()
        revision += 1
        let values = records, writer = writer, revision = revision
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                try await Task.detached { try writer.save(values, revision: revision) }.value
                if self?.revision == revision { self?.storageError = nil }
            } catch is CancellationError { }
            catch { if self?.revision == revision { self?.storageError = error.localizedDescription } }
        }
    }
}

extension RepositoryStore {
    func networkContext(profileID: UUID? = nil, useAssignment: Bool = true, journal: NetworkActivityStore? = nil) -> GitNetworkContext {
        let profile = profileID.flatMap { id in authentication.profiles.first { $0.id == id } } ?? (useAssignment ? snapshot.flatMap { authentication.profile(for: $0.root) } : nil)
        let reference = profile.map { GitCredentialReference(id: $0.id, host: $0.host, executable: Bundle.main.executablePath ?? CommandLine.arguments[0]) }
        let activity = journal ?? networkActivity
        return GitNetworkContext(credential: reference) { [weak activity] event in
            Task { @MainActor in activity?.receive(event) }
        }
    }
    func configureNetworkContext() {
        guard let snapshot else { return }
        GitNetworkContexts.register(networkContext(), root: snapshot.root, owner: networkContextOwner)
        networkRegisteredRoot = snapshot.root
    }
    func disconnectNetworkContext() {
        if let root = networkRegisteredRoot { GitNetworkContexts.remove(root: root, owner: networkContextOwner) }
        networkRegisteredRoot = nil
    }
    func testRemote(_ name: String) {
        guard !isBusy, let repository else { return }
        isBusy = true; activity = String(localized: "Testing remote access…"); connectionTestMessage = String(localized: "Testing “\(name)”…")
        operationTask = Task {
            defer { isBusy = false; activity = "" }
            do {
                _ = try await GitProcess.run(["ls-remote", "--heads", "--", name], at: repository.root, timeout: 30)
                connectionTestMessage = String(localized: "Read access to “\(name)” verified. Push permissions are checked by the server during Push.")
            } catch { connectionTestMessage = String(localized: "Remote test failed. \(networkFailureAdvice(error.localizedDescription))"); operationFeedback?.failure = connectionTestMessage }
        }
    }
}
