import Foundation
import GitCore

protocol WorkingDiffReading: Sendable {
    func diff(_ change: FileChange, staged: Bool, context: Int, ignoreWhitespace: Bool, in repository: GitRepository) async throws -> String
}
struct GitWorkingDiffReader: WorkingDiffReading {
    func diff(_ change: FileChange, staged: Bool, context: Int, ignoreWhitespace: Bool, in repository: GitRepository) async throws -> String {
        try await repository.diff(change, staged: staged, context: context, ignoreWhitespace: ignoreWhitespace, cancellable: true)
    }
}
struct WorkingDiffRequest: Equatable { let path: String; let staged: Bool; let context: Int; let whitespace: Bool }

struct WorkingFilesInput: Equatable, Sendable {
    let changes: [FileChange]
    let browser: [WorkingFileEntry]
    let all: Bool
    let ignored: Bool
    let assumed: Bool
    let query: String
    let conflictsOnly: Bool
    let orderByStatus: Bool
}
struct WorkingFilesPresentation: Sendable {
    var files: [WorkingFileEntry] = []
    var paths: Set<String> = []
    static let empty = Self()
    nonisolated static func visible(_ input: WorkingFilesInput) -> [WorkingFileEntry] {
        let changes = Dictionary(input.changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var entries = (input.all || input.ignored || input.assumed) ? input.browser : []
        let known = Set(entries.map(\.path))
        entries += input.changes.filter { !known.contains($0.path) }.map { WorkingFileEntry(path: $0.path, change: $0, isTracked: !$0.isUntracked, isIgnored: false, assumeUnchanged: false, skipWorktree: false) }
        return entries.compactMap { entry in
            let change = changes[entry.path]
            guard (input.ignored || !entry.isIgnored), (input.all || change != nil || entry.isIgnored || (input.assumed && entry.assumeUnchanged)), (input.assumed || !entry.assumeUnchanged) else { return nil }
            return WorkingFileEntry(path: entry.path, change: change, isTracked: entry.isTracked, isIgnored: entry.isIgnored, assumeUnchanged: entry.assumeUnchanged, skipWorktree: entry.skipWorktree)
        }
    }
    nonisolated static func make(_ input: WorkingFilesInput) -> Self {
        let files = visible(input).filter { (!input.conflictsOnly || $0.change?.isConflicted == true) && (input.query.isEmpty || $0.path.localizedCaseInsensitiveContains(input.query)) }.sorted {
            if input.orderByStatus, $0.status != $1.status { return $0.status.localizedStandardCompare($1.status) == .orderedAscending }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return Self(files: files, paths: Set(files.map(\.path)))
    }
}

extension RepositoryStore {
    var workingFilesInput: WorkingFilesInput { WorkingFilesInput(changes: changes, browser: workingFileEntries, all: showAllFiles, ignored: showIgnoredFiles, assumed: showAssumeUnchanged, query: destination == .workingCopy ? search : "", conflictsOnly: workingOnlyConflicts, orderByStatus: workingOrderByStatus) }
    func rebuildWorkingList() async {
        let input = workingFilesInput, token = repositoryToken, generation = UUID()
        workingListGeneration = generation; isLoadingWorkingFiles = true
        let value = await Task.detached(priority: .userInitiated) { WorkingFilesPresentation.make(input) }.value
        guard repositoryToken == token, workingListGeneration == generation else { return }
        guard !Task.isCancelled else { isLoadingWorkingFiles = false; return }
        workingList = value; isLoadingWorkingFiles = false
        reconcileWorkingSelection()
    }
    func setWorkingSelection(_ paths: Set<String>) {
        let next = paths.intersection(workingList.paths)
        let added = next.subtracting(selectedWorkingFiles)
        selectedWorkingFiles = next
        let path = workingList.files.first { added.contains($0.path) }?.path
            ?? (selectedChange.flatMap { next.contains($0) ? $0 : nil })
            ?? workingList.files.first { next.contains($0.path) }?.path
        if let path, let file = workingList.files.first(where: { $0.path == path }) {
            if selectedChange != path { selectBrowserFile(file) }
        } else { clearBrowserSelection() }
    }
    func reconcileWorkingSelection() {
        selectedWorkingFiles.formIntersection(workingList.paths)
        guard destination == .workingCopy else { return }
        if let path = selectedChange, workingList.paths.contains(path) { return }
        if let first = workingList.files.first(where: { selectedWorkingFiles.contains($0.path) }) { selectBrowserFile(first) }
        else { clearBrowserSelection() }
    }
    func workingTargets(_ context: String? = nil) -> [FileChange] {
        let paths = context.map { selectedWorkingFiles.contains($0) ? selectedWorkingFiles : [$0] } ?? selectedWorkingFiles
        return changes.filter { paths.contains($0.path) }
    }
    func toggleWorkingFile(_ file: FileChange) {
        if !selectedWorkingFiles.contains(file.path) { setWorkingSelection([file.path]) }
        if file.isConflicted { selectChange(file, staged: false) }
        else if file.isStaged && !file.isUnstaged { unstageSelectedFiles(file.path) }
        else { stageSelectedFiles(file.path) }
    }
    func stageSelectedFiles(_ context: String? = nil) { stage(workingTargets(context).filter { !$0.isConflicted && $0.isUnstaged }) }
    func unstageSelectedFiles(_ context: String? = nil) { unstage(workingTargets(context).filter { !$0.isConflicted && $0.isStaged }) }
    var commitUnavailableReason: String? {
        guard snapshot != nil, !isChoosingRepository else { return "Open a repository to commit." }
        if isBusy || isOpeningRepository { return "Wait for the current operation." }
        if snapshot?.operation != RepositoryOperation.none { return "Finish or abort the current Git operation." }
        if changes.contains(where: \.isConflicted) { return "Resolve conflicts before committing." }
        if staged.isEmpty && !(amend && snapshot?.hasHEAD == true) { return "Stage changes to include in the commit." }
        if commitSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a commit subject." }
        return nil
    }
}
