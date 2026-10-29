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

    var title: String {
        let name = command.title ?? activity.trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
        if phase == .running { return isRefreshing ? name + " · " + String(localized: "Refreshing…") : activity }
        let result = phase == .succeeded ? (warning == nil ? String(localized: "Completed") : String(localized: "Action required")) : phase.title
        return name + " · " + result
    }
}

extension RepositoryStore {
    var isFetching: Bool {
        isBackgroundFetching || (operationFeedback?.command == .fetch && operationFeedback?.phase == .running)
    }

    var feedbackNetworkRecord: NetworkActivityRecord? {
        guard let feedback = operationFeedback else { return nil }
        // Bound both ends so an old completion never links to a later background fetch.
        return networkActivity?.records.first {
            $0.repositoryPath == feedback.repository && $0.started >= feedback.started && $0.started <= (feedbackFinishedAt ?? .distantFuture)
        }
    }

    /// Called by the shared busy/activity lifecycle, so custom workflows receive the same feedback.
    func beginCurrentOperationFeedback() {
        guard isBusy, !isBackgroundFetching, !suppressOperationFeedback, !isOpeningRepository, !isChoosingRepository, let snapshot else { return }
        if operationFeedback?.phase == .running {
            operationFeedback?.activity = activity
            return
        }
        clearOperationFeedback()
        let feedback = RepositoryOperationFeedback(repository: snapshot.root.path, activity: activity)
        operationFeedback = feedback
        // Fast local actions finish without flashing a banner or moving the working copy.
        operationFeedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard self?.operationFeedback?.id == feedback.id else { return }
            self?.operationFeedback?.isVisible = true
        }
    }

    func configureOperationFeedback(_ command: RepositoryOperationKind) {
        guard operationFeedback?.phase == .running else { return }
        operationFeedbackTask?.cancel()
        operationFeedback?.command = command
        operationFeedback?.isVisible = true
    }

    func finishCurrentOperationFeedback() {
        guard !suppressOperationFeedback, let feedback = operationFeedback, feedback.phase == .running else { return }
        operationFeedbackTask?.cancel()
        feedbackFinishedAt = Date()
        let cancelled = feedbackNetworkRecord?.phase == .cancelled
        let phase: GitNetworkEvent.Phase = cancelled ? .cancelled : feedback.failure == nil ? .succeeded : .failed
        operationFeedback?.phase = phase
        if phase == .succeeded, snapshot?.operation != RepositoryOperation.none || changes.contains(where: \.isConflicted) {
            operationFeedback?.warning = String(localized: "Review the working copy to resolve conflicts or finish the current operation.")
        }
        if phase == .succeeded, !feedback.isVisible, operationFeedback?.warning == nil { clearOperationFeedback(); return }
        operationFeedback?.isVisible = true
        guard phase != .failed, operationFeedback?.warning == nil else { return }
        operationFeedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            self?.dismissOperationFeedback(feedback.id)
        }
    }

    func dismissOperationFeedback(_ id: UUID) {
        guard operationFeedback?.id == id, operationFeedback?.phase != .running else { return }
        clearOperationFeedback()
    }

    func clearOperationFeedback() {
        operationFeedbackTask?.cancel(); operationFeedbackTask = nil; operationFeedback = nil; feedbackFinishedAt = nil
    }
}
