import Foundation
import GitCore

struct AutomaticStashRequest: Identifiable {
    let id = UUID()
    let title: String.LocalizationValue
    let refresh: MutationRefresh
    var feedback: RepositoryOperationKind? = nil
    let action: @Sendable (GitRepository) async throws -> Void
}

extension RepositoryStore {
    func protectedPerform(_ title: String.LocalizationValue, protect: Bool = true, refresh: MutationRefresh = .full, feedback: RepositoryOperationKind? = nil, action: @escaping @Sendable (GitRepository) async throws -> Void) {
        guard !isBusy else { return }
        guard protect else { perform(title, refresh: refresh, feedback: feedback, action: action); return }
        guard automaticStash == nil else { error = String(localized: "Review the pending automatic stash before starting another operation."); return }
        if !changes.isEmpty, AppPreferences.shared.offerAutomaticStash {
            let request = AutomaticStashRequest(title: title, refresh: refresh, feedback: feedback, action: action)
            if integrationRequest != nil || pullRequest != nil || managementRequest != nil || rebaseRequest != nil || showingBranchSheet {
                pendingAutomaticStashRequest = request
            } else { automaticStashRequest = request }
        } else { perform(title, refresh: refresh, feedback: feedback, action: action) }
    }

    func presentPendingAutomaticStash() {
        guard let pendingAutomaticStashRequest else { return }
        automaticStashRequest = pendingAutomaticStashRequest; self.pendingAutomaticStashRequest = nil
    }

    func runAutomaticStash(_ request: AutomaticStashRequest, message: String, restoreAfter: Bool) {
        perform(request.title, refresh: request.refresh, feedback: request.feedback) {
            try await $0.performWithAutomaticStash(title: String(localized: request.title), message: message, restoreAfter: restoreAfter, action: request.action)
        }
    }

    func completeAutomaticStash(keepSaved: Bool) {
        guard let record = automaticStash else { return }
        perform("Finishing automatic stash recovery…", refresh: .workingTree) { try await $0.finishAutomaticStashReview(expected: record.id, keepSavedStash: keepSaved) }
    }

    func restoreAutomaticStash() {
        perform("Restoring automatic stash…", refresh: .workingTree) { try await $0.finishAutomaticStashIfReady() }
    }
}
