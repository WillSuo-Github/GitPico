# Validation — GitPico 0.4 — 2026-10-23–24

## Scope and reference

Added interactive rebase for linear history, durable Git history undo/redo, and Reflog browsing/recovery. Swift + SwiftUI; minimum deployment target remains macOS 26.0.

Inspected the installed Tower 18 through native accessibility and screenshots. Both apps opened the isolated `dist/HistoryReview-8zsc58q6` repository. Tower's Rebase form, commit context menu, Edit Undo/Redo entries, and Reflog were inspected without executing a Tower history rewrite. The available Tower Rebase sheet was an ordinary branch integration form; GitPico's interactive plan editor is an additional implementation, not a claim that an identical Tower editor was observed.

Matched the observed 320-point Reflog list, hash/action/date row structure, colored action badges, and Reflog position after Branches Review. Existing commit metadata/Changeset/Tree views are reused for old commits. References: [Tower Rebase](evidence/tower-rebase-reference.png), [Tower Reflog](evidence/tower-reflog-reference.png).

## Automated checks

**45 Swift Testing tests passed, zero failures**, in 52.255 seconds. [Full log](evidence/swift-test-v4.log). A subsequent focused rebase edit/progress test also passed after adding exact step-count assertions: [progress log](evidence/rebase-progress-test-v4.log).

New tests cover:

- Reorder, Reword, Squash, Fixup and Drop in one plan; exact resulting messages/files and retained original tips.
- Edit stop, stage/amend, reopen the repository actor and continue using durable rebase message files.
- Reject dirty worktrees, stale HEAD/branch state, malformed/duplicate/missing steps and invalid folding order.
- Rebase conflicts: Abort restores the original branch; Skip continues; the completed rewrite can be undone.
- Undo/redo a commit with staged, unstaged and untracked contents preserved exactly; Amend and initial-commit undo/redo; journal persistence; reject external HEAD movement.
- Reflog event timestamps and preview of an unreachable commit; recover a branch without overwriting an existing branch.
- Restore tracked history only from a clean worktree; protect ignored files that would be replaced.
- Resolve a merge conflict, reopen the repository, continue, undo and redo the completed integration.

The older line-staging/conflict/remote/history tests remain in the full suite.

## Native interaction checks

Performed only in the isolated history-review repository:

1. Loaded four commits from the tagged base, changed the first to Reword, edited its full message, and marked a later commit Edit. Executed the plan.
2. The app switched to Working Copy at the edit stop. Opened Amend Paused Commit, changed its full message, amended and continued. History and Git log showed `Add a calmer welcome` and `Tune native sidebar spacing` with new hashes.
3. Opened the Undo Interactive Rebase preview. Undo restored original HEAD `103e9f528207a7f4b3c88363944c5e5fe1e04d5e` and the original commit chain. The Redo shortcut/preview restored rewritten HEAD `7a6933b3432797ac74b8832857e98e5cdfe68035`.
4. Opened Reflog and selected an old event. Its old commit metadata loaded even though the commit was outside the current branch history. Created `recovered/before-native-rebase` at the old hash; current HEAD stayed unchanged.
5. Restored HEAD to the initial tagged base using Keep staged and working files. Git reported four added/staged files, with all content retained. Undo Restore HEAD restored the rewritten tip and a clean working copy.
6. Opened a commit's context menu and verified Interactive Rebase, Restore HEAD, branch recovery and Copy Hash entries. The explicit move-later/move-earlier buttons changed the visible plan order and selection.
7. Started a two-commit plan with an Edit stop. The operation card reported Step 1 of 2, excluding internal message-update commands. Relaunched the actual application through the build/run script: it reopened the same detached edit stop, showed the same progress and exposed Amend/Continue. Continued successfully, then undid this second rewrite to return the demo to the earlier reviewed tip and a clean worktree.
8. Left both Tower and GitPico on the same repository's Reflog, refreshed after the final operation. GitPico's list divider reported exactly 320 points.

Screenshots: [Interactive plan](evidence/interactive-rebase-v4.png), [Edit stop](evidence/rebase-edit-stop-v4.png), [Restarted stop](evidence/rebase-restarted-v4.png), [Undo preview](evidence/undo-preview-v4.png), [Reflog](evidence/reflog-v4.png). [Reflog accessibility snapshot](evidence/reflog-v4-ax.txt). Build/signature/deployment evidence: [launch](evidence/build-and-launch-v4.log), [signature](evidence/signature-v4.log), [deployment target](evidence/deployment-target-v4.log).

## Repairs during validation

- An optional-operation comparison treated `.none` as Optional.none and disabled the new menu. Use the explicit RepositoryOperation.none case.
- The initial draggable List exposed combined rows without individually accessible action controls. Added a selected-commit action picker and explicit accessible move controls outside the rows.
- Progress initially counted internal message-update commands; now counts only replayed commit actions.
- Restore previews displayed Unborn branch while loading; now show Loading until HEAD is known.
- Bulk staging retried paths for fully staged deletions. Ignore already-staged-only entries when staging. Preserved [initial regression](evidence/restore-regression-initial-v4.log) and [fixed test](evidence/restore-regression-fixed-v4.log).
- Added ignored-item collision checks before tracked-file restoration and before replaying historical trees.
- Moved the history context actions into CommitRow's own context menu so nested menus do not hide them.

## Boundaries

- Interactive rebase supports ancestor-based linear ranges of at most 200 commits, with optional replay onto another commit. Root and merge-containing ranges are refused explicitly. Arbitrary user exec commands are not exposed.
- Undo/redo covers app-created commit/Amend, merge/rebase/cherry-pick and Restore HEAD records. It is not a general undo system for staging, checkout, stash, remote actions or external Git commands. Incompatible external HEAD/branch changes disable a record.
- Commit undo preserves index/worktree contents. File-restoring undo requires a clean working copy and protects ignored/untracked destinations. No hard-reset recovery mode is exposed.
- Per-worktree undo metadata keeps up to 50 records. Original/rewritten tips and rebase helper files remain in GitPico recovery storage; no automatic pruning is implemented.
- Native text undo keeps Command-Z. Git undo/redo uses Option-Command-Z / Shift-Option-Command-Z and review sheets.
- Reflog search filters loaded events; paging loads 500 at a time, capped at 10,000 events. Event dates come from reflog timestamps, not commit author dates.
- Runtime host is macOS 27.0.1; macOS 26 runtime execution, production remote authentication/signing, large-repository performance and full accessibility/appearance audits remain unverified.
- Sources are uncommitted and unpushed. No remote publication or forced push was performed.

## Git references

Implementation follows the documented [interactive rebase/continue/skip/abort behavior](https://git-scm.com/docs/git-rebase), [local reflog behavior](https://git-scm.com/docs/git-reflog) and [conditional reference updates](https://git-scm.com/docs/git-update-ref). Application behavior above was verified by the listed tests and native checks.
