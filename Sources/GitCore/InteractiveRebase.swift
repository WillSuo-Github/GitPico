import Foundation

public enum RebaseAction: String, CaseIterable, Sendable { case pick, reword, edit, squash, fixup, drop }

public struct RebaseStep: Identifiable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let originalMessage: String
    public var action: RebaseAction = .pick
    public var message: String
    public var isMerge: Bool = false
}

public struct InteractiveRebasePlan: Sendable {
    public let position: HeadPosition
    public let base: String
    public let originalHashes: [String]
    public var onto: String
    public var steps: [RebaseStep]
    public var preserveMerges: Bool = false
    public var autosquash: Bool = false
}

public struct RebaseProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let isEditing: Bool
    public let hasConflicts: Bool
    public let currentMessage: String
}

extension GitRepository {
    public func rebasePlan(after revision: String) async throws -> InteractiveRebasePlan {
        guard try await currentOperation() == .none else { throw GitFailure("Finish or abort the active operation first.") }
        let position = try await headPosition()
        guard position.branch != "HEAD", let head = position.hash else { throw GitFailure("Check out a branch with commits before rebasing.") }
        let base = revision == "--root" ? "--root" : try await verifiedCommit(revision)
        if base != "--root" {
            let ancestor = try await GitProcess.run(["merge-base", "--is-ancestor", base, head], at: root, allowed: [0, 1])
            guard ancestor.status == 0 else { throw GitFailure("The starting commit must be an ancestor of HEAD.") }
        }
        let range = base == "--root" ? head : base + ".." + head
        let merges = try await GitProcess.run(["rev-list", "--merges", range, "--"], at: root)
        let mergeHashes = Set(merges.text.split(separator: "\n").map(String.init))
        let output = try await GitProcess.run(["log", "--reverse", "--topo-order", "--max-count=201", "--format=%H%x00%B%x00", range, "--"], at: root)
        let values = output.text.components(separatedBy: "\0")
        var steps: [RebaseStep] = []; var index = 0
        while index + 1 < values.count {
            let hash = values[index].trimmingCharacters(in: .newlines)
            let message = values[index + 1].trimmingCharacters(in: .newlines)
            steps.append(RebaseStep(hash: hash, originalMessage: message, message: message, isMerge: mergeHashes.contains(hash))); index += 2
        }
        guard !steps.isEmpty else { throw GitFailure("There are no commits after the selected starting point.") }
        guard steps.count <= 200 else { throw GitFailure("Choose a shorter range (up to 200 commits).") }
        return InteractiveRebasePlan(position: position, base: base, originalHashes: steps.map(\.hash), onto: base == "--root" ? "" : base, steps: steps, preserveMerges: !mergeHashes.isEmpty)
    }

    public func startInteractiveRebase(_ plan: InteractiveRebasePlan) async throws {
        guard try await headPosition() == plan.position, try await currentOperation() == .none else { throw GitFailure("HEAD or the current branch changed. Reload the rebase plan.") }
        try await requireCleanHistoryWorktree()
        let fresh = try await rebasePlan(after: plan.base)
        guard fresh.originalHashes == plan.originalHashes, Set(plan.steps.map(\.hash)) == Set(plan.originalHashes), plan.steps.count == plan.originalHashes.count else { throw GitFailure("The rebase plan must contain every original commit exactly once. Use Drop to remove commits.") }
        guard plan.preserveMerges == fresh.preserveMerges else { throw GitFailure("The merge topology changed. Reload the plan.") }
        if plan.preserveMerges {
            guard plan.steps.map(\.hash) == plan.originalHashes, plan.steps.allSatisfy({ step in step.isMerge == fresh.steps.first(where: { $0.hash == step.hash })?.isMerge && (!step.isMerge || step.action == .pick) && ![.squash, .fixup].contains(step.action) }) else { throw GitFailure("Merge-preserving plans retain topology and merge messages. Use Pick, Reword, Edit or Drop on ordinary commits without reordering; merge rows are retained.") }
        }
        let onto = plan.onto.isEmpty && plan.base == "--root" ? "" : try await verifiedCommit(plan.onto)
        for target in Set(plan.originalHashes + [plan.base, onto]).filter({ !$0.isEmpty && $0 != "--root" }) { try await protectUntrackedDestinations(target) }
        var preceding = false
        for step in plan.steps {
            if step.action == .drop { continue }
            if step.action == .fixup || step.action == .squash {
                guard preceding else { throw GitFailure("Squash and Fixup require an earlier retained commit.") }
            }
            if step.action == .reword || step.action == .squash {
                guard !step.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !step.message.contains("\0") else { throw GitFailure("Enter a commit message for every Reword or Squash step.") }
            }
            preceding = true
        }
        guard preceding else { throw GitFailure("Keep at least one commit in the plan.") }
        let directory = try await gitPicoURL("rebase/" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var todo: [String] = []
        for (index, step) in plan.steps.enumerated() {
            if step.isMerge { continue }
            var replacement: [String] = []
            let command = step.action == .squash ? "fixup" : step.action == .reword ? "pick" : step.action.rawValue
            replacement.append("\(command) \(step.hash)")
            if step.action == .reword || step.action == .squash {
                let message = directory.appendingPathComponent("message-\(index).txt")
                try Data(step.message.utf8).write(to: message, options: .atomic)
                replacement.append("exec /usr/bin/git commit --amend --cleanup=verbatim --file " + shellQuote(message.path))
            }
            todo += replacement
            try Data((replacement.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent(step.hash))
        }
        let planURL = directory.appendingPathComponent("todo")
        try Data((todo.joined(separator: "\n") + "\n").utf8).write(to: planURL, options: .atomic)
        let editor = directory.appendingPathComponent("sequence-editor.sh")
        let editorText: String
        if plan.preserveMerges {
            editorText = """
            #!/bin/sh
            set -eu
            output=\(shellQuote(directory.appendingPathComponent("edited-todo").path))
            while IFS= read -r line; do
              case "$line" in
                'pick '*) key="${line#pick }"; key="${key%% *}"; replacement=\(shellQuote(directory.path))/"$key"; test -f "$replacement"; /bin/cat "$replacement" ;;
                *) printf '%s\\n' "$line" ;;
              esac
            done < "$1" > "$output"
            exec /bin/cp "$output" "$1"
            """
        } else { editorText = "#!/bin/sh\nexec /bin/cp " + shellQuote(planURL.path) + " \"$1\"\n" }
        try Data(editorText.utf8).write(to: editor, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editor.path)
        try await beginHistoryAction(localized("Interactive Rebase"), operation: .rebase)
        do {
            let range = plan.base == "--root" ? ["--root"] : [plan.base]
            let destination = onto.isEmpty ? [] : ["--onto", onto]
            // Autosquash is applied to the reviewed linear plan, preserving explicit edits.
            _ = try await GitProcess.run(["-c", "core.abbrev=\(plan.position.hash?.count ?? 40)", "-c", "rebase.abbreviateCommands=false", "rebase", "--interactive", "--force-rebase", "--no-autosquash", "--no-autostash", "--no-update-refs", plan.preserveMerges ? "--rebase-merges=no-rebase-cousins" : "--no-rebase-merges", "--reschedule-failed-exec", "--empty=stop"] + destination + range, at: root, timeout: 120, sequenceEditor: editor)
            try await finishHistoryAction()
        } catch {
            if try await currentOperation() == .none { try await clearPendingHistory() }
            throw error
        }
    }

    public func rebaseProgress() async throws -> RebaseProgress? {
        guard try await currentOperation() == .rebase else { return nil }
        let path = try await GitProcess.run(["rev-parse", "--git-path", "rebase-merge"], at: root).text.trimmingCharacters(in: .newlines)
        let directory = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        func read(_ name: String) -> String { (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        let done = read("done").split(separator: "\n").filter { !$0.hasPrefix("#") }
        let pending = read("git-rebase-todo").split(separator: "\n").filter { !$0.hasPrefix("#") }
        let commitCommands: Set<String> = ["pick", "reword", "edit", "squash", "fixup"]
        func count(_ lines: [Substring]) -> Int { lines.filter { commitCommands.contains(String($0.split(separator: " ").first ?? "")) }.count }
        let conflicts = GitParser.status(try await GitProcess.run(["status", "--porcelain=v1", "-z"], at: root).data).contains(where: \.isConflicted)
        let message = try await GitProcess.run(["show", "--no-show-signature", "-s", "--format=%B", "HEAD", "--"], at: root).text.trimmingCharacters(in: .newlines)
        return RebaseProgress(completed: count(done), total: count(done) + count(pending), isEditing: done.last?.hasPrefix("edit ") == true && !conflicts, hasConflicts: conflicts, currentMessage: message)
    }

    public func amendRebaseStop(message: String) async throws {
        guard let progress = try await rebaseProgress(), progress.isEditing, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitFailure("Rebase is not stopped at an editable commit, or the message is empty.") }
        _ = try await GitProcess.run(["commit", "--amend", "--cleanup=verbatim", "-m", message], at: root, timeout: 120)
    }

    public func skipRebaseCommit() async throws {
        guard try await currentOperation() == .rebase else { throw GitFailure("No rebase is in progress.") }
        _ = try await GitProcess.run(["rebase", "--skip"], at: root, timeout: 120, acceptGeneratedMessage: true)
        try await finishHistoryAction()
        try await finishAutomaticStashIfReady()
    }
}

extension InteractiveRebasePlan {
    public mutating func applyAutosquash() throws {
        guard !preserveMerges else { throw GitFailure("Autosquash is available for linear plans. Merge-preserving plans keep their topology.") }
        var retained: [RebaseStep] = []
        for var step in steps {
            let subject = step.originalMessage.components(separatedBy: "\n").first ?? ""
            let prefix = subject.hasPrefix("fixup! ") ? "fixup! " : subject.hasPrefix("squash! ") ? "squash! " : ""
            if !prefix.isEmpty {
                let target = String(subject.dropFirst(prefix.count))
                if let index = retained.firstIndex(where: { $0.hash.hasPrefix(target) || $0.originalMessage.components(separatedBy: "\n").first == target }) {
                    step.action = prefix == "fixup! " ? .fixup : .squash
                    if step.action == .squash { step.message = retained[index].message + "\n\n" + step.originalMessage.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines) }
                    var insertion = index + 1
                    while insertion < retained.count && [.fixup, .squash].contains(retained[insertion].action) { insertion += 1 }
                    retained.insert(step, at: insertion); continue
                }
            }
            retained.append(step)
        }
        steps = retained; autosquash = true
    }
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
