# Repository opening — 2026-10-29

Opening a repository from the library showed a progress overlay immediately and
waited for multiple independent metadata reads in sequence. On the running
MacBook installation, two RepositoryOpen events reported 281.6 ms and 300.1 ms.
Those events measure the store operation, excluding the workspace's initial
repository validation and foreground painting.

## Change

- Read the snapshot, automatic-stash recovery, remotes, reference organization,
  Undo availability and Rebase progress concurrently. Publish the new repository
  after these required reads succeed, preserving the existing repository and
  draft if a required read fails.
- Load related repositories and Git Flow concurrently with the working-file
  presentation. Opening still awaits all three, so their state is available when
  actions become enabled.
- Show the opening overlay only after 200 ms. Completing or leaving the opening
  view cancels the delay. Other library operations retain their existing progress
  feedback.

## Before and after

Both runs used the existing disposable fixture on the Mac mini, macOS 27.2 arm64:
10,000 commits, 150 additional branches, 2,000 untracked files, 9 worktrees and
3 configured remotes. Each measurement used a fresh workspace. No remote server
was contacted. The measured interval covers workspace open through completion of
all initial reads, independent of the progress-overlay delay.

| Measurement | Before | After |
| --- | ---: | ---: |
| Sample 1 | 251.6 ms | 127.6 ms |
| Sample 2 | 249.0 ms | 129.9 ms |
| Sample 3 | 251.4 ms | 135.3 ms |
| Median | 251.4 ms | 129.9 ms |
| Git commands per sample | 26 | 26 |

The median decreased by 48.3%. Raw samples and command timings are in
[before.json](evidence/repository-open-20261029/before.json) and
[after.json](evidence/repository-open-20261029/after.json). Concurrent phase times
overlap and must not be summed. This is a data-readiness benchmark, not a
foreground first-paint measurement or a prediction for every repository.

## Verification

- Full GitPico app target plus three GitCore open/read/process regression cases:
  183 test definitions passed, 21 opt-in definitions skipped, zero failures.
  Parameterized invocation counts differ from definition counts.
- The opt-in before and after benchmarks each passed separately; HEAD stayed
  unchanged.
- New coverage checks that staged/untracked files, pinned branches, remote
  configuration, worktrees and Git Flow remain available after opening, and that
  invalid recovery metadata leaves the previous repository and draft intact.
- Packaged launch and native-menu verification results are recorded in
  [launch-summary.json](evidence/repository-open-20261029/launch-summary.json).

Tests and launch verification suppress windows and activation. The installed
MacBook application was not replaced. No foreground mouse or macOS 26 runtime
acceptance was performed. Marketing version remains 0.0.1 and deployment target
remains macOS 26.0.
