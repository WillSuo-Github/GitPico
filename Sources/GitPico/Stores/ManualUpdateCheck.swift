import Foundation
import GitCore
import Observation
import Sparkle

@MainActor protocol UpdateCheckPresenting: AnyObject {
    func showPreparation(cancellation: @escaping () -> Void)
    func dismissPreparation()
    func showPreparationFailure(_ message: String)
    func beginUpdateCheck()
}

extension SPUStandardUpdaterController: UpdateCheckPresenting {
    func showPreparation(cancellation: @escaping () -> Void) { userDriver.showUserInitiatedUpdateCheck(cancellation: cancellation) }
    func dismissPreparation() { userDriver.dismissUpdateInstallation() }
    func showPreparationFailure(_ message: String) {
        Task { await userDriver.showUpdaterError(GitFailure(message)) }
    }
    func beginUpdateCheck() { checkForUpdates(nil) }
}

/// Gives manual checks visible, cancellable feedback before Sparkle has a feed URL.
@MainActor @Observable final class ManualUpdateCheck {
    private(set) var preparing = false
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    func start(presenter: any UpdateCheckPresenting, prepare: @escaping @MainActor () async throws -> Void, cancelled: @escaping @MainActor () -> Void) {
        guard !preparing else { return }
        let token = UUID(); generation = token; preparing = true
        presenter.showPreparation { [weak self, weak presenter] in
            guard let self, self.generation == token else { return }
            self.generation = UUID(); self.task?.cancel(); self.task = nil; self.preparing = false
            presenter?.dismissPreparation(); cancelled()
        }
        guard generation == token else { return }
        task = Task {
            defer { if generation == token { preparing = false; task = nil } }
            do {
                try await prepare()
                try Task.checkCancellation()
                guard generation == token else { return }
                presenter.dismissPreparation()
                presenter.beginUpdateCheck()
            } catch is CancellationError {
                if generation == token { presenter.dismissPreparation(); cancelled() }
            } catch {
                guard generation == token else { return }
                presenter.dismissPreparation()
                presenter.showPreparationFailure(GitLogRedaction.clean(error.localizedDescription))
            }
        }
    }
}
