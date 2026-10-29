# Repository operation feedback — 2026-10-29

## Observed problem and design

A manually started Fetch was discoverable only in the bottom status bar. The
source toolbar button became disabled without a running label, and an empty file
list incorrectly displayed “Loading files…”. The user's requirement extends to
Pull, Push and the other repository workflows.

The revised feedback uses the existing NoticeBanner immediately below the
repository toolbar. Fetch, Pull, Push and Synchronize show it immediately and
change the corresponding toolbar button to a spinner and running label. Other
manual operations reveal the same banner after 200 ms; operations that finish
before it appears do not flash a success banner. Successful visible results
remain for six seconds. Failures and actionable warnings remain until dismissed
or replaced by the next operation. Cancellation has a distinct terminal state.

The original Fetch evidence is retained:
[before](evidence/fetch-feedback-20261029/01-before-fetching.png),
[after](evidence/fetch-feedback-20261029/02-after-fetching.png),
[completed](evidence/fetch-feedback-20261029/03-after-completed.png).

The expanded native-window evidence includes:
[Pull](evidence/operation-feedback-20261029/pulling-top.png),
[Pull, dark/narrow](evidence/operation-feedback-20261029/pulling-dark-narrow-top.png),
[Push](evidence/operation-feedback-20261029/pushing-top.png),
[Push, dark/narrow](evidence/operation-feedback-20261029/pushing-dark-narrow-top.png),
[Push completed](evidence/operation-feedback-20261029/push-completed-top.png).

## Coverage and lifecycle

| Entry point | Feedback | Verification |
| --- | --- | --- |
| Toolbar/menu Fetch; reviewed remote Fetch | Immediate banner and Fetch button progress | Actual delayed local Fetch, reviewed Fetch, failure, retry, cancellation |
| Pull Merge / Rebase | Immediate Pull progress through integration and repository refresh | Both policies with divergent local/remote commits |
| Synchronize (Pull then Push) | One parent workflow; Pull success cannot finish the banner before Push | Actual local Pull followed by a delayed pre-push hook |
| Direct Push | Immediate Push progress, completed/rejected result | Actual local bare-server success and non-fast-forward rejection |
| Publish / reviewed Push / remote reference deletion | Same Push executor and immediate feedback | Actual publication with upstream setup; source audit of the shared deletion executor |
| Automatic stash around Pull | Preserves Pull identity through stash, Pull and recovery | Actual Pull and restoration of staged file contents |
| Merge conflict / abort | Failure remains visible; existing conflict workflow remains available | Actual Pull conflict and abort, with HEAD and file-content checks |
| Commit | Shared lifecycle, including warnings after a successful commit | Slow and rejecting commit hooks; committed result with failed Undo-record persistence |
| Stage / unstage, checkout, merge, rebase, stash, recovery | Shared busy/activity lifecycle with 200 ms reveal | App regression exercises existing executors; staging and delayed Commit explicitly check visibility |
| Worktree/submodule administration, exports, Git Flow, LFS, pointer repair/migration | Shared busy/activity lifecycle, including custom task executors | Source audit plus existing app regression; not every extension/transport is exercised end to end |
| Worktree/submodule batch | Incomplete nonthrowing report becomes a persistent actionable warning | Source audit; existing successful batch regression |
| Remote connection test | Failure cannot become a green success result | Actual inaccessible local remote |
| Automatic refresh / automatic Fetch | No manual-operation banner; does not replace a retained manual result | Actual automatic Fetch and retained manual-failure checks |
| Clone from an open repository | Shared lifecycle; failure captured before releasing busy state | Missing local source rejection; existing repository HEAD retained |
| Repository picker, opening, review/preparation sheets | Retain their existing contextual progress | Opening suppression and existing navigation/window regressions |

RepositoryOperationFeedback follows the shared manual busy/activity lifecycle,
including custom workflows that do not call perform. Explicit operation kinds
are passed through protectedPerform and AutomaticStashRequest, rather than
inferred from localized labels or child network events. Refresh is an explicit
stage. Completion waits for the entire parent executor to finish.

Feedback has its own operation ID, start/end bounds, captured failure and warning,
and reveal/dismiss task. A stale dismissal cannot erase a retry. Network details
are scoped to the repository and operation time interval; later background work
cannot be mistaken for the earlier result. Successful repository opening clears
the prior feedback. Background refresh/fetch does not start a manual lifecycle.

Fetch permits read-only file/history navigation, search and draft editing.
Staging, commits and integration retain their busy-state write guards. Pull's
internal fetch never grants these browsing permissions while integration runs.
The file list shows its loader only while it is actually loading files.

## Verification

Full app regression: **194 test definitions passed, 22 opt-in definitions skipped,
zero failures**. Parameterized cases are included in the device-level totals.
The machine-readable result is retained in
[regression-summary.json](evidence/operation-feedback-20261029/regression-summary.json).
Current build/launch results are recorded in
[launch-summary.json](evidence/operation-feedback-20261029/launch-summary.json).
The focused workflow run passed all eight new test definitions. The four original
Fetch checks also passed after the generalization. The expanded native capture
passed separately, asserting no app activation and zero visible windows. A final
three-test follow-up passed after the Clone failure-order fix and the refresh
label adjustment: failed Clone, manual Fetch, and successful Commit with an Undo
warning. See [final-edges-summary.json](evidence/operation-feedback-20261029/final-edges-summary.json)
and [visual-summary.json](evidence/operation-feedback-20261029/visual-summary.json).

All acceptance Git writes used disposable local repositories and local bare
remotes. No personal repository or external server received acceptance writes.
The native captures use real Git operations and an offscreen native window, in
light/dark appearances and 1080/1440-point widths. An exploratory failure capture
was removed because SwiftUI's error alert bypassed the hidden-window policy;
final visual capture excludes this path, and failure scenarios run without a
hosted window. Failures are not claimed as hidden-window visual acceptance.

Host: macOS 27.2 arm64. No macOS 26 runtime, foreground mouse, VoiceOver or full
accessibility acceptance is claimed. The installed MacBook application was not
replaced. Distribution is tracked separately by the release manifest and GitHub Release.
