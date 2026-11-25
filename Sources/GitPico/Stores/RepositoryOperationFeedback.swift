import Foundation
import GitCore

/// Identifies the parent workflow, including composite Pull + Push and automatic stash recovery.
enum RepositoryOperationKind: Sendable {
    case local, fetch, pull, push, synchronize

    var title: String? {
        switch self {
        case .local: nil
        case .fetch: String(localized: "Fetch")
        case .pull: String(localized: "Pull")
        case .push: String(localized: "Push")
        case .synchronize: String(localized: "Synchronize")
        }
    }
}

struct RepositoryOperationFeedback: Identifiable {
    let id = UUID()
    var command: RepositoryOperationKind = .local
    let repository: String
    let started = Date()
    var activity: String
    var phase: GitNetworkEvent.Phase = .running
    var isVisible = false
    var isRefreshing = false
    var failure: String?
    var warning: String?

    var outcomeTitle: String {
        phase == .succeeded ? (warning == nil ? String(localized: "Completed") : String(localized: "Action required")) : phase.title
    }

    var title: String {
        let name = command.title ?? activity.trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
        if phase == .running { return isRefreshing ? name + " · " + String(localized: "Refreshing…") : activity }
        return name + " · " + outcomeTitle
    }
}

extension RepositoryStore {
    var isFetching: Bool { isManualFetching || isBackgroundFetching }
    var isPerformingActivity: Bool { isBusy || isFetching }
    var showsRepositoryStatus: Bool { snapshot != nil && !isChoosingRepository }
    var isPerformingStatusActivity: Bool { isBusy || (showsRepositoryStatus && isFetching) }

    var operationFeedback: RepositoryOperationFeedback? {
        selectedFeedbackEntry?.feedback
    }

    var feedbackFinishedAt: Date? {
        selectedFeedbackEntry?.finishedAt
    }

    private var selectedFeedbackEntry: (feedback: RepositoryOperationFeedback, finishedAt: Date?)? {
        guard showsRepositoryStatus else { return nil }
        if let exclusive = exclusiveFeedback, exclusive.phase == .running, exclusive.isVisible {
            return (exclusive, exclusiveFeedbackFinishedAt)
        }
        if let fetch = fetchFeedback, fetch.phase == .running {
            return (fetch, fetchFeedbackFinishedAt)
        }
        if let exclusive = exclusiveFeedback, exclusive.phase == .running {
            return (exclusive, exclusiveFeedbackFinishedAt)
        }
        switch (exclusiveFeedback, fetchFeedback) {
        case (let exclusive?, let fetch?):
            if exclusive.isVisible != fetch.isVisible {
                return exclusive.isVisible ? (exclusive, exclusiveFeedbackFinishedAt) : (fetch, fetchFeedbackFinishedAt)
            }
            let exclusiveDate = exclusiveFeedbackFinishedAt ?? exclusive.started
            let fetchDate = fetchFeedbackFinishedAt ?? fetch.started
            return exclusiveDate >= fetchDate ? (exclusive, exclusiveFeedbackFinishedAt) : (fetch, fetchFeedbackFinishedAt)
        case (let exclusive?, nil):
            return (exclusive, exclusiveFeedbackFinishedAt)
        case (nil, let fetch?):
            return (fetch, fetchFeedbackFinishedAt)
        case (nil, nil):
            return nil
        }
    }

    var feedbackNetworkRecord: NetworkActivityRecord? {
        guard let entry = selectedFeedbackEntry else { return nil }
        return networkRecord(for: entry.feedback, finishedAt: entry.finishedAt)
    }

    func networkRecord(for feedback: RepositoryOperationFeedback, finishedAt: Date?) -> NetworkActivityRecord? {
        return networkActivity?.records.first {
            $0.repositoryPath == feedback.repository && $0.started >= feedback.started && $0.started <= (finishedAt ?? .distantFuture)
        }
    }

    var activeFetchNetworkRecord: NetworkActivityRecord? {
        if isManualFetching, let feedback = fetchFeedback, feedback.phase == .running, !feedback.isRefreshing {
            return networkActivity?.records.first {
                $0.repositoryPath == feedback.repository && $0.command == "fetch" && $0.started >= feedback.started && $0.phase == .running
            }
        }
        if isBackgroundFetching, let path = snapshot?.root.path {
            return networkActivity?.records.first {
                $0.repositoryPath == path && $0.command == "fetch" && $0.started >= lastBackgroundFetch && $0.phase == .running
            }
        }
        return nil
    }

    var activeStatusNetworkRecord: NetworkActivityRecord? {
        if let clone = cloneSession, clone.isRunning, let recordID = clone.networkRecordID {
            return networkActivity?.records.first { $0.id == recordID && $0.phase == .running }
        }
        guard showsRepositoryStatus else { return nil }
        if isBusy, let feedback = exclusiveFeedback, feedback.phase == .running, !feedback.isRefreshing,
           let record = networkRecord(for: feedback, finishedAt: exclusiveFeedbackFinishedAt), record.phase == .running {
            return record
        }
        return activeFetchNetworkRecord
    }

    var latestStatusNetworkRecord: NetworkActivityRecord? {
        guard showsRepositoryStatus, let path = snapshot?.root.path else { return nil }
        let record = networkActivity?.records.first { $0.repositoryPath == path && $0.phase != .running }
        return record?.id == dismissedStatusNetworkRecord ? nil : record
    }

    /// Called by the shared busy/activity lifecycle, so custom workflows receive the same feedback.
    func beginCurrentOperationFeedback() {
        guard isBusy, !suppressOperationFeedback, !isOpeningRepository, !isChoosingRepository, let snapshot else { return }
        if exclusiveFeedback?.phase == .running {
            exclusiveFeedback?.activity = activity
            return
        }
        clearExclusiveOperationFeedback()
        let feedback = RepositoryOperationFeedback(repository: snapshot.root.path, activity: activity)
        exclusiveFeedback = feedback
        // Fast local actions finish without flashing a banner or moving the working copy.
        exclusiveFeedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard self?.exclusiveFeedback?.id == feedback.id else { return }
            self?.exclusiveFeedback?.isVisible = true
        }
    }

    func configureOperationFeedback(_ command: RepositoryOperationKind) {
        guard exclusiveFeedback?.phase == .running else { return }
        exclusiveFeedbackTask?.cancel()
        exclusiveFeedback?.command = command
        exclusiveFeedback?.isVisible = true
    }

    func finishCurrentOperationFeedback() {
        guard !suppressOperationFeedback, let feedback = exclusiveFeedback, feedback.phase == .running else { return }
        exclusiveFeedbackTask?.cancel()
        let finishedAt = Date()
        exclusiveFeedbackFinishedAt = finishedAt
        let cancelled = networkRecord(for: feedback, finishedAt: finishedAt)?.phase == .cancelled
        let phase: GitNetworkEvent.Phase = cancelled ? .cancelled : feedback.failure == nil ? .succeeded : .failed
        exclusiveFeedback?.phase = phase
        if phase == .succeeded, snapshot?.operation != RepositoryOperation.none || changes.contains(where: \.isConflicted) {
            exclusiveFeedback?.warning = String(localized: "Review the working copy to resolve conflicts or finish the current operation.")
        }
        // Keep the latest result available on demand, even when a quick action needs no visual acknowledgement.
        if phase == .succeeded, !feedback.isVisible, exclusiveFeedback?.warning == nil { return }
        exclusiveFeedback?.isVisible = true
        guard phase != .failed, exclusiveFeedback?.warning == nil else { return }
        exclusiveFeedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard self?.exclusiveFeedback?.id == feedback.id else { return }
            self?.exclusiveFeedback?.isVisible = false
        }
    }

    func beginFetchFeedback(repository: String, activity: String) {
        clearFetchOperationFeedback()
        var feedback = RepositoryOperationFeedback(repository: repository, activity: activity)
        feedback.command = .fetch
        feedback.isVisible = true
        fetchFeedback = feedback
    }

    func finishFetchFeedback() {
        guard let feedback = fetchFeedback, feedback.phase == .running else { return }
        fetchFeedbackTask?.cancel()
        let finishedAt = Date()
        fetchFeedbackFinishedAt = finishedAt
        let cancelled = networkRecord(for: feedback, finishedAt: finishedAt)?.phase == .cancelled
        let phase: GitNetworkEvent.Phase = cancelled ? .cancelled : feedback.failure == nil ? .succeeded : .failed
        fetchFeedback?.phase = phase
        fetchFeedback?.isRefreshing = false
        fetchFeedback?.isVisible = true
        guard phase != .failed, fetchFeedback?.warning == nil else { return }
        fetchFeedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard self?.fetchFeedback?.id == feedback.id else { return }
            self?.fetchFeedback?.isVisible = false
        }
    }

    func cancelFetch() {
        if let recordID = activeFetchNetworkRecord?.id { networkActivity?.cancel(recordID) }
        fetchTask?.cancel(); fetchTask = nil
        isManualFetching = false
        isBackgroundFetching = false
        clearFetchOperationFeedback()
    }

    func inspectOperationNetworkActivity() {
        networkActivitySelection = (activeStatusNetworkRecord ?? feedbackNetworkRecord ?? latestStatusNetworkRecord)?.id ?? cloneSession?.networkRecordID
        showingNetworkActivity = true
    }

    func dismissOperationFeedback(_ id: UUID) {
        if let feedback = exclusiveFeedback, feedback.id == id, feedback.phase != .running {
            dismissedStatusNetworkRecord = networkRecord(for: feedback, finishedAt: exclusiveFeedbackFinishedAt)?.id
            clearExclusiveOperationFeedback()
            return
        }
        if let feedback = fetchFeedback, feedback.id == id, feedback.phase != .running {
            dismissedStatusNetworkRecord = networkRecord(for: feedback, finishedAt: fetchFeedbackFinishedAt)?.id
            clearFetchOperationFeedback()
        }
    }

    func clearExclusiveOperationFeedback() {
        exclusiveFeedbackTask?.cancel(); exclusiveFeedbackTask = nil; exclusiveFeedback = nil; exclusiveFeedbackFinishedAt = nil
    }

    func clearFetchOperationFeedback() {
        fetchFeedbackTask?.cancel(); fetchFeedbackTask = nil; fetchFeedback = nil; fetchFeedbackFinishedAt = nil
    }

    func clearOperationFeedback() {
        clearExclusiveOperationFeedback()
        clearFetchOperationFeedback()
    }
}
