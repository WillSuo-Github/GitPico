import AppKit
import Foundation
import GitCore
import Observation

struct ConflictDraft: Codable, Sendable {
    let snapshot: ConflictSnapshot
    let text: String
}

enum Destination: Hashable, Sendable, Codable {
    case worktrees, submodules, workingCopy, history, reflog, stashes, branchesReview, repositorySettings, reference(String), fileHistory(String, String), comparison(String)
    var title: String {
        switch self {
        case .worktrees: "Worktrees"
        case .submodules: "Submodules"
        case .workingCopy: "Working Copy"
        case .history: "History"
        case .reflog: "Reflog"
        case .stashes: "Stashes"
        case .branchesReview: "Branches Review"
        case .repositorySettings: "Settings"
        case .fileHistory(let path, _): path.isEmpty ? "File History" : "File History – " + path
        case .comparison: "Compare Revisions"
        case .reference(let ref): ref.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/remotes/", with: "").replacingOccurrences(of: "refs/tags/", with: "")
        }
    }
    var ref: String? { if case .reference(let ref) = self { ref } else { nil } }
    var searchPlaceholder: String? {
        switch self {
        case .workingCopy: "Search for File"
        case .history, .reference: "Search for Message"
        case .reflog: "Search Reflog"
        case .branchesReview: "Search for Branch with Name"
        case .stashes: "Search for Stash"
        case .worktrees: "Search Worktrees"
        case .submodules: "Search Submodules"
        case .repositorySettings: nil
        case .fileHistory: "Search Loaded File History"
        case .comparison: nil
        }
    }
}

@MainActor @Observable
final class RepositoryStore {
    @ObservationIgnored weak var workspace: RepositoryWorkspace?
    var sidebarFilter = "" { didSet { workspace?.scheduleSessionSave() } }
    var backStack: [Destination] = []
    var forwardStack: [Destination] = []
    @ObservationIgnored var navigationBookmarks: [Destination:NavigationBookmark] = [:]
    @ObservationIgnored var navigationBookmarkOrder: [Destination] = []
    @ObservationIgnored var pendingHistorySelection: String?
    @ObservationIgnored var historyNeedsReveal = false
    var historyReveal: HistoryReveal?
    var historyOptions = HistoryOptions() { didSet { workspace?.scheduleSessionSave() } }
    var isLoadingHistory = false
    var historyPresentation = HistoryPresentation.empty
    var historyError: String?
    @ObservationIgnored var historyTask: Task<Void,Never>?
    @ObservationIgnored var detailTask: Task<Void,Never>?
    @ObservationIgnored var operationTask: Task<Void,Never>?
    @ObservationIgnored var historyGeneration = UUID()
    @ObservationIgnored var historyCache: [HistoryCacheKey:HistoryPresentation] = [:]
    @ObservationIgnored var historyCacheOrder: [HistoryCacheKey] = []
    @ObservationIgnored var historyRevisionHints: [String:HistoryRevision] = [:]
    @ObservationIgnored var commitDetailCache: [String:CommitDetail] = [:]
    @ObservationIgnored let historyReader: any HistoryReading
    @ObservationIgnored var metadataEpoch = UUID()
    @ObservationIgnored var metadataDirty: Set<DeferredMetadata> = []
    @ObservationIgnored var metadataTask: Task<Void,Never>?
    @ObservationIgnored let mutationRefreshReader: any MutationRefreshReading
    @ObservationIgnored let workingDiffReader: any WorkingDiffReading
    var diffContext = 7
    var ignoreWhitespace = false
    var amend = false
    var signOff = false
    var integrationRequest: IntegrationRequest?
    var pullRequest: PullReviewRequest?
    var trackingAfterPull = false
    var rebaseRequest: RebaseRequest?
    var recoveryRequest: RecoveryRequest?
    var undoAvailability: UndoAvailability?
    var rebaseProgress: RebaseProgress?
    var showingRebaseEdit = false
    var showingHostedReviews = false
    var showingLFSLocks = false
    var settingsTab = "General"
    var lfsRequest: LFSRequest?
    var flowRequest: FlowRequest?
    var lfsState: LFSState?
    var lfsChanges: [LFSChangeRecord] = []
    var lfsTransfers: [LFSTransferReport] = []
    var lfsProgress = ""
    var lfsError: String?
    var flowConfiguration: GitFlowConfiguration?
    var activeFlow: GitFlowRecord?
    var flowHistory: [GitFlowRecord] = []
    var workflowError: String?
    var configuration: RepositoryConfiguration?
    var managedRemotes: [RemoteConfiguration] = []
    var organization = ReferenceOrganization()
    var managementRequest: ManagementRequest?
    var stashRequest: StashRequest?
    var localChangeRequest: LocalChangeRequest?
    var worktrees: [ManagedWorktree] = []
    var submodules: [ManagedSubmodule] = []
    var worktreeError: String?
    var submoduleError: String?
    var infrastructureRequest: RepositoryInfrastructureRequest?
    var relatedAdministrationRequest: RelatedAdministrationRequest?
    var relatedBatchProgress: RelatedBatchReport?
    @ObservationIgnored var relatedBatchTask: Task<Void, Never>?
    var worktreeRequest: WorktreeRequest?
    var submoduleRequest: SubmoduleRequest?
    var historicalRequest: HistoricalRequest?
    var snapshot: RepositorySnapshot?
    var destination: Destination = .workingCopy { didSet { workspace?.scheduleSessionSave() } }
    @ObservationIgnored var dragActions: [UUID: PicoDragAction] = [:]
    var selectedWorkingFiles: Set<String> = [] { didSet { workspace?.scheduleSessionSave() } }
    var showAllFiles = false { didSet { workspace?.scheduleSessionSave() } }
    var showIgnoredFiles = false { didSet { workspace?.scheduleSessionSave() } }
    var showAssumeUnchanged = false
    var workingFileEntries: [WorkingFileEntry] = []
    var workingList = WorkingFilesPresentation.empty
    var workingOrderByStatus = false
    var workingOnlyConflicts = false
    var isLoadingWorkingFiles = false
    @ObservationIgnored var workingListGeneration = UUID()
    var commitWarning: String?
    var commitFeedback: String?
    var diffError: String?
    @ObservationIgnored var workingDiffRequest: WorkingDiffRequest?
    var externalToolRequest: ExternalToolRequest?
    var showingExternalToolSettings = false
    var toolPreferences = ExternalToolPreferences()
    @ObservationIgnored var externalToolRunner = ExternalToolRunner()
    @ObservationIgnored var fileBrowserGeneration = UUID()
    var selectedChange: String? { didSet { workspace?.scheduleSessionSave() } }
    var stagedDiff = false { didSet { workspace?.scheduleSessionSave() } }
    var selectedCommit: Commit? { didSet { workspace?.scheduleSessionSave() } }
    var commitDetail: CommitDetail?
    var selectedCommitPath: String? { didSet { workspace?.scheduleSessionSave() } }
    var automaticStash: AutomaticStashRecord?
    var automaticStashRequest: AutomaticStashRequest?
    var pendingAutomaticStashRequest: AutomaticStashRequest?
    var selectedStash: Stash?
    var diff = ""
    var isLoadingDiff = false
    var isBusy = false {
        didSet {
            if isBusy { automaticRefreshEpoch = UUID() }
            else if automaticRefreshPending { requestAutomaticRefresh() }
        }
    }
    var isAutomaticallyRefreshing = false
    var isBackgroundFetching = false
    var automaticRefreshError: String?
    @ObservationIgnored var fileMonitor: RepositoryFileMonitor?
    @ObservationIgnored var automaticMonitorTask: Task<Void, Never>?
    @ObservationIgnored var automaticRefreshTask: Task<Void, Never>?
    @ObservationIgnored var automaticRefreshPending = false
    @ObservationIgnored var automaticRefreshEpoch = UUID()
    @ObservationIgnored var backgroundFetchTask: Task<Void, Never>?
    @ObservationIgnored var lastBackgroundFetch = Date.distantPast
    var activity = ""
    var error: String?
    var search = "" { didSet { workspace?.scheduleSessionSave() } }
    var searchFocusRequest: UUID?
    var searchActionsRequest: UUID?
    var commitSubject = "" { didSet { if !commitSubject.isEmpty { commitFeedback = nil; commitWarning = nil }; if oldValue != commitSubject { workspace?.recordDraft(self) } } }
    var commitBody = "" { didSet { if !commitBody.isEmpty { commitFeedback = nil; commitWarning = nil }; if oldValue != commitBody { workspace?.recordDraft(self) } } }
    var conflictDrafts: [String: ConflictDraft] = [:] { didSet { scheduleConflictDraftSave() } }
    var conflictDraftSaveError: String?
    var showingConflictDrafts = false
    var showingNetworkActivity = false
    var showingAuthentication = false
    var authenticationAfterNetwork = false
    var networkAfterAuthentication = false
    var connectionTestMessage: String?
    var authentication: AuthenticationStore
    var networkActivity: NetworkActivityStore?
    @ObservationIgnored let networkContextOwner = UUID()
    @ObservationIgnored var networkRegisteredRoot: URL?
    @ObservationIgnored var conflictDraftArchive: ConflictDraftArchive?
    @ObservationIgnored var conflictDraftSaveTask: Task<Void, Never>?
    @ObservationIgnored var conflictDraftRevision: UInt64 = 0
    @ObservationIgnored var loadingConflictDrafts = false
    var showingBranchSheet = false
    var showingStashSheet = false
    var creationRequest: RepositoryCreationRequest?
    var library: RepositoryLibrary
    var recentPaths: [String] { library.recentPaths }
    var showingRepositoryLibrary = false
    var showingQuickOpen = false
    init(library: RepositoryLibrary? = nil, historyReader: any HistoryReading = GitHistoryReader(), workingDiffReader: any WorkingDiffReading = GitWorkingDiffReader(), mutationRefreshReader: any MutationRefreshReading = GitMutationRefreshReader(), authentication: AuthenticationStore? = nil, networkActivity: NetworkActivityStore? = nil) {
        let library = library ?? RepositoryLibrary()
        self.library = library; self.authentication = authentication ?? AuthenticationStore(file: library.file.deletingLastPathComponent().appendingPathComponent("authentication.json"))
        self.networkActivity = networkActivity ?? NetworkActivityStore(directory: library.file.deletingLastPathComponent())
        self.historyReader = historyReader; self.workingDiffReader = workingDiffReader; self.mutationRefreshReader = mutationRefreshReader
    }
    @ObservationIgnored var lastOpenReport: RepositoryOpenReport?
    var lastUpdated: Date?
    @ObservationIgnored var repository: GitRepository?
    @ObservationIgnored var detailToken = UUID()
    @ObservationIgnored var repositoryToken = UUID()
    @ObservationIgnored var draftBeforeAmend: (String, String)?
    deinit {
        automaticMonitorTask?.cancel(); automaticRefreshTask?.cancel(); backgroundFetchTask?.cancel(); conflictDraftSaveTask?.cancel()
        if let root = networkRegisteredRoot { GitNetworkContexts.remove(root: root, owner: networkContextOwner) }
    }

    var title: String { snapshot?.root.lastPathComponent ?? "GitPico" }
    var changes: [FileChange] { snapshot?.changes ?? [] }
    var staged: [FileChange] { changes.filter(\.isStaged) }
    var unstaged: [FileChange] { changes.filter { $0.isUnstaged || $0.isConflicted } }
    var canCommit: Bool { commitUnavailableReason == nil }
    var currentChange: FileChange? { changes.first { $0.path == selectedChange } }

    func startup() async {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--repository"), arguments.indices.contains(index + 1) {
            await open(URL(fileURLWithPath: arguments[index + 1]))
        } else if let path = recentPaths.first { await open(URL(fileURLWithPath: path)) }
    }

    func showRepositories() { if let workspace { workspace.showRepositories(from: self) } else { showingRepositoryLibrary = true } }

    func chooseRepository() {
        if let workspace { workspace.chooseRepository(from: self); return }
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Git Repository"
        panel.message = "Choose a Git working directory."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Repository"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.open(url) }
        }
    }

    func open(_ url: URL) async {
        if let workspace { await workspace.open(url, from: self); return }
        await openInPlace(url)
    }

    func reopenCurrentRepository(_ url: URL) async {
        if let workspace {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            let currentStillExists = snapshot.map { FileManager.default.fileExists(atPath: $0.root.appendingPathComponent(".git").path) } ?? false
            let replacing = snapshot?.root.path == canonical.path || !currentStillExists
            await workspace.open(url, from: self, replacing: replacing)
        } else { await openInPlace(url) }
    }

    func openInPlace(_ url: URL, openedRepository: GitRepository? = nil) async {
        guard !isBusy else { return }
        do { try flushConflictDrafts() } catch { self.error = error.localizedDescription; return }
        isBusy = true; activity = "Opening repository…"
        let timing = RepositoryOpenTiming(); var succeeded = false
        defer { isBusy = false; activity = ""; lastOpenReport = timing.finish(succeeded: succeeded) }
        do {
            let repo: GitRepository
            if let openedRepository { repo = openedRepository } else { repo = try await timing.measure("validate") { try await GitRepository.open(url) } }
            let data = try await timing.measure("snapshot") { try await repo.snapshot(countHistory: false) }
            cancelPreviewWork(); clearHistoryCache(); commitDetailCache = [:]; historyPresentation = .empty; historyError = nil
            searchFocusRequest = nil; searchActionsRequest = nil; metadataEpoch = UUID(); metadataTask?.cancel(); metadataTask = nil; metadataDirty = []; repositoryToken = UUID(); detailToken = UUID(); workingFileEntries = []; workingList = .empty; workingOnlyConflicts = false; commitFeedback = nil; commitWarning = nil; diffError = nil; workingDiffRequest = nil; showAllFiles = false; showIgnoredFiles = false; dragActions = [:]; selectedWorkingFiles = []
            lfsRequest = nil; flowRequest = nil; lfsState = nil; lfsChanges = []; lfsTransfers = []; lfsProgress = ""; lfsError = nil; flowConfiguration = nil; activeFlow = nil; flowHistory = []; workflowError = nil
            managementRequest = nil; stashRequest = nil; localChangeRequest = nil; historicalRequest = nil; worktreeRequest = nil; submoduleRequest = nil; relatedAdministrationRequest = nil; infrastructureRequest = nil; relatedBatchProgress = nil; worktrees = []; submodules = []; externalToolRequest = nil; showingBranchSheet = false; showingStashSheet = false
            automaticStashRequest = nil; pendingAutomaticStashRequest = nil
            automaticStash = try await timing.measure("automatic-stash") { try await repo.automaticStashRecord() }
            disconnectNetworkContext()
            repository = repo; snapshot = data
            configureNetworkContext()
            managedRemotes = try await timing.measure("remotes") { try await repo.remoteConfigurations() }
            organization = try await timing.measure("organization") { try await repo.referenceOrganization() }
            undoAvailability = try await timing.measure("undo") { try await repo.undoAvailability() }
            rebaseProgress = try await timing.measure("rebase") { try await repo.rebaseProgress() }
            backStack = []; forwardStack = []; navigationBookmarks = [:]; navigationBookmarkOrder = []; pendingHistorySelection = nil; historyNeedsReveal = false; historyReveal = nil; draftBeforeAmend = nil
            destination = .workingCopy; search = ""; historyOptions = HistoryOptions(); amend = false; signOff = false; configuration = nil
            selectedChange = nil; selectedCommit = nil; selectedStash = nil
            commitDetail = nil; selectedCommitPath = nil; diff = ""
            commitSubject = ""; commitBody = ""
            conflictDraftArchive = nil; conflictDrafts = [:]
            await loadConflictDrafts(at: data.root)
            do { try library.recordOpened(data.root) }
            catch { self.error = "Repository opened, but the library could not be saved: " + error.localizedDescription }
            await timing.measure("related") { await loadRelatedRepositories() }
            await timing.measure("workflow") { await loadWorkflowState() }
            await timing.measure("working-list") { await rebuildWorkingList() }
            lastUpdated = Date(); succeeded = true
            if workspace?.monitoringEnabled == true { startAutomaticRefresh() }
        } catch { self.error = error.localizedDescription }
    }

    func refresh() {
        guard !isBusy, repository != nil else { return }
        cancelPreviewWork(); clearHistoryCache(); commitDetailCache = [:]
        isBusy = true; activity = "Refreshing…"
        operationTask = Task {
            defer { isBusy = false; activity = "" }
            do { try await reload() } catch { self.error = error.localizedDescription }
        }
    }

    func reload() async throws {
        guard let repository else { return }
        metadataEpoch = UUID(); metadataTask?.cancel()
        cancelPreviewWork(); clearHistoryCache(); commitDetailCache = [:]
        if let ref = destination.ref, (try? await repository.commit(at: ref)) == nil { destination = .history; selectedCommit = nil; commitDetail = nil }
        snapshot = try await repository.snapshot(ref: destination.ref, options: historyOptions)
        automaticStash = try await repository.automaticStashRecord()
        managedRemotes = try await repository.remoteConfigurations(); organization = try await repository.referenceOrganization()
        if let selectedStash {
            self.selectedStash = snapshot?.stashes.first(where: { $0.hash == selectedStash.hash && $0.subject == selectedStash.subject })
                ?? (destination == .stashes ? snapshot?.stashes.first : nil)
        }
        undoAvailability = try await repository.undoAvailability(); rebaseProgress = try await repository.rebaseProgress()
        await loadRelatedRepositories(); await loadWorkflowState()
        if showAllFiles || showIgnoredFiles || showAssumeUnchanged { workingFileEntries = try await repository.workingFiles(includeIgnored: showIgnoredFiles) }
        if snapshot?.operation == RepositoryOperation.none { workingOnlyConflicts = false }
        await rebuildWorkingList()
        lastUpdated = Date()
        if let selected = currentChange { selectChange(selected, staged: selected.isStaged && (!selected.isUnstaged || stagedDiff)) }
        else if selectedChange != nil && !workingFileEntries.contains(where: { $0.path == selectedChange }) { selectedChange = nil; diff = "" }
        if destination != .reflog, let selectedCommit {
            if let updated = snapshot?.commits.first(where: { $0.id == selectedCommit.id }) {
                self.selectedCommit = updated
            } else {
                self.selectedCommit = nil; commitDetail = nil; diff = ""
            }
        }
        metadataDirty.subtract([.remotes, .stashes, .organization])
        switch destination {
        case .history, .reference:
            requestHistory()
        case .worktrees, .submodules, .workingCopy, .reflog, .stashes, .branchesReview, .repositorySettings, .fileHistory, .comparison: break
        }
    }

    func navigate(_ value: Destination, record: Bool = true) {
        guard (!isBusy || isBackgroundFetching), value != destination else { return }
        rememberNavigation()
        if record { backStack.append(destination); if backStack.count > 100 { backStack.removeFirst() }; forwardStack = [] }
        cancelPreviewWork(); searchFocusRequest = nil; detailToken = UUID(); destination = value; restoreNavigation(value)
        selectedCommit = nil; commitDetail = nil; selectedChange = nil
        selectedStash = nil; selectedCommitPath = nil; diff = ""; isLoadingDiff = false
        if isHistoryDestination { requestHistory(preservingSelection: false) }
        requestDeferredMetadata(value)
    }

    func clearBrowserSelection() { detailTask?.cancel(); detailToken = UUID(); workingDiffRequest = nil; selectedChange = nil; diff = ""; diffError = nil; isLoadingDiff = false }

    func selectBrowserFile(_ file: WorkingFileEntry) {
        if let change = file.change { selectChange(change, staged: change.isStaged && !change.isUnstaged) }
        else { clearBrowserSelection(); selectedChange = file.path }
    }

    func selectChange(_ change: FileChange, staged: Bool) {
        let staged = staged ? change.isStaged : !change.isUnstaged && change.isStaged
        let request = WorkingDiffRequest(path: change.path, staged: staged, context: diffContext, whitespace: ignoreWhitespace)
        if workingDiffRequest == request, selectedChange == change.path, diffError == nil { return }
        selectedChange = change.path; stagedDiff = staged
        workingDiffRequest = request
        let context = diffContext, whitespace = ignoreWhitespace, reader = workingDiffReader
        loadDiff(inlineError: true) { try await reader.diff(change, staged: staged, context: context, ignoreWhitespace: whitespace, in: $0) }
    }

    func selectCommit(_ commit: Commit) {
        guard let repository else { return }
        if selectedCommit?.hash == commit.hash, commitDetail != nil || isLoadingDiff { return }
        detailTask?.cancel()
        selectedCommit = commit; commitDetail = nil; selectedCommitPath = nil; diff = ""
        let token = UUID(); detailToken = token
        if let cached = commitDetailCache[commit.hash] { commitDetail = cached; isLoadingDiff = false; return }
        isLoadingDiff = true
        detailTask = Task {
            do {
                let detail = try await repository.detail(commit, cancellable: true)
                guard detailToken == token, !Task.isCancelled else { return }
                if commitDetailCache.count >= 32 { commitDetailCache = [:] }
                commitDetailCache[commit.hash] = detail
                commitDetail = detail; isLoadingDiff = false
            } catch is CancellationError { }
            catch {
                guard detailToken == token else { return }
                self.error = error.localizedDescription; isLoadingDiff = false
            }
        }
    }

    func selectCommitFile(_ path: String) {
        guard let selectedCommit else { return }
        selectedCommitPath = path
        loadDiff { try await $0.commitDiff(selectedCommit, path: path, cancellable: true) }
    }

    func selectStash(_ stash: Stash) {
        selectedStash = stash
    }

    private func loadDiff(inlineError: Bool = false, _ action: @escaping @Sendable (GitRepository) async throws -> String) {
        guard let repository else { return }
        detailTask?.cancel()
        let token = UUID(); detailToken = token; isLoadingDiff = true; diff = ""; diffError = nil
        detailTask = Task {
            do {
                let value = try await action(repository)
                guard detailToken == token else { return }
                diff = value; isLoadingDiff = false
            } catch is CancellationError { }
            catch {
                guard detailToken == token else { return }
                if inlineError { self.diffError = error.localizedDescription } else { self.error = error.localizedDescription }; isLoadingDiff = false
            }
        }
    }

    func perform(_ title: String, refresh: MutationRefresh = .full, action: @escaping @Sendable (GitRepository) async throws -> Void) {
        guard !isBusy, let repository else { return }
        cancelPreviewWork(); commitFeedback = nil; commitWarning = nil
        isBusy = true; activity = title
        operationTask = Task {
            defer { isBusy = false; activity = "" }
            do { try await action(repository) }
            catch { self.error = error.localizedDescription }
            // A rejected merge or stash application can still change the index and working copy.
            // Refresh once, independently of write success, while preserving the original Git error.
            do {
                switch refresh {
                case .full: try await reload()
                case .index: try await reloadIncrementally(history: false)
                case .workingTree: try await reloadIncrementally(history: false, includingRecovery: true)
                }
            } catch {
                self.error = [self.error, "Repository refresh failed. " + error.localizedDescription].compactMap { $0 }.joined(separator: "\n\n")
            }
            await showActiveWork()
        }
    }

    private func showActiveWork() async {
        if snapshot?.operation != RepositoryOperation.none || changes.contains(where: \.isConflicted) {
            if destination != .workingCopy {
                rememberNavigation(); cancelPreviewWork(); destination = .workingCopy; restoreNavigation(.workingCopy); search = ""
                await rebuildWorkingList()
            }
            if let file = changes.first(where: \.isConflicted) {
                if !workingList.paths.contains(file.path) { search = ""; await rebuildWorkingList() }
                setWorkingSelection([file.path]); selectChange(file, staged: false)
            }
        }
    }

    func stage(_ files: [FileChange]) { guard !files.isEmpty else { return }; perform("Staging changes…", refresh: .index) { try await $0.stage(files) } }
    func unstage(_ files: [FileChange]) { guard !files.isEmpty else { return }; perform("Unstaging changes…", refresh: .index) { try await $0.unstage(files) } }
    func commit() {
        guard canCommit, let repository else { return }
        let message = commitSubject + (commitBody.isEmpty ? "" : "\n\n" + commitBody)
        let shouldAmend = amend; let shouldSignOff = signOff
        commitFeedback = nil; commitWarning = nil; cancelPreviewWork()
        isBusy = true; activity = "Creating commit…"
        operationTask = Task {
            defer { isBusy = false; activity = "" }
            let outcome: CommitOutcome
            do { outcome = try await repository.commit(message: message, amend: shouldAmend, signOff: shouldSignOff) }
            catch { self.error = error.localizedDescription; try? await reloadIncrementally(history: false); return }
            draftBeforeAmend = nil; commitSubject = ""; commitBody = ""; amend = false; diff = ""
            commitFeedback = shouldAmend ? "Commit amended." : "Commit created."
            commitWarning = outcome.undoWarning
            do { try await reloadIncrementally(history: true) }
            catch {
                undoAvailability = nil
                commitWarning = [commitWarning, "The commit was created, but repository refresh failed. " + error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
                await rebuildWorkingList()
                if let file = currentChange { selectChange(file, staged: file.isStaged && !file.isUnstaged) }
            }
        }
    }

    func sync(_ action: GitRepository.SyncAction) {
        guard canUseRepository, snapshot?.remotes.isEmpty == false, action == .fetch || canIntegrate else { return }
        if action == .pull, let snapshot {
            pullRequest = PullReviewRequest(head: snapshot.head, upstream: snapshot.references.first(where: \.isCurrent)?.upstream ?? "")
        } else if action == .push, let current = snapshot?.references.first(where: \.isCurrent), current.isLocal, current.upstream.isEmpty {
            manage(.publish(current, nil, nil, false))
        } else { protectedPerform("\(action.rawValue.capitalized)…", protect: false) { try await $0.sync(action) } }
    }
    func switchBranch(_ ref: Reference) {
        guard checkoutUnavailableReason(ref) == nil else { return }
        protectedPerform("Checking out \(ref.name)…", refresh: .workingTree) { try await $0.switchBranch(ref) }
    }
    func createBranch(_ name: String) { perform("Creating branch…", refresh: .workingTree) { try await $0.createBranch(name) } }
    func saveStash(_ message: String) { perform("Saving stash…", refresh: .workingTree) { try await $0.saveStash(message: message) } }
    func applyStash(_ stash: Stash) { stashAction(.apply(stash)) }
}
