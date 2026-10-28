import AppKit
import AuthenticationServices
import GitCore

@MainActor protocol OAuthBrowserAuthenticating: AnyObject {
    func authenticate(_ url: URL, callbackScheme: String) async throws -> URL
    func cancel()
}

@MainActor final class OAuthBrowserSession: NSObject, OAuthBrowserAuthenticating, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var generation: UUID?
    func authenticate(_ url: URL, callbackScheme: String) async throws -> URL {
        guard continuation == nil, !ProcessInfo.processInfo.arguments.contains("--background-testing"), !NativeStartupVerification.enabled, NSApp.keyWindow != nil else { throw appFailure("Open Authentication in an active GitPico window to sign in.") }
        try Task.checkCancellation()
        let generation = UUID()
        self.generation = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let completion = Self.mainActorCompletion { [weak self] callback, error in
                    if let callback { self?.finish(.success(callback), generation: generation) }
                    else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { self?.finish(.failure(CancellationError()), generation: generation) }
                    else { self?.finish(.failure(appFailure("Browser sign-in could not finish. Start sign-in again.")), generation: generation) }
                }
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme, completionHandler: completion)
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                if !session.start() { finish(.failure(appFailure("The system could not open browser sign-in."))); return }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    self?.finish(.failure(appFailure("Browser sign-in expired. Start sign-in again.")), generation: generation)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError()), generation: generation) } }
    }
    // AuthenticationServices may invoke its completion on a Safari XPC queue.
    // Construct the entry closure outside MainActor before hopping to UI state.
    nonisolated static func mainActorCompletion(_ completion: @escaping @MainActor @Sendable (URL?, Error?) -> Void) -> @Sendable (URL?, Error?) -> Void {
        { callback, error in
            Task { @MainActor in completion(callback, error) }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? ASPresentationAnchor() }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<URL, Error>, generation: UUID? = nil) {
        if let generation, generation != self.generation { return }
        guard let continuation else { return }
        self.continuation = nil; self.generation = nil; timeout?.cancel(); timeout = nil
        session?.cancel(); session = nil
        continuation.resume(with: result)
    }
}
