# Repository opening performance — 2026-10-25

Packaged build: **0.01 / 20261025225536**, minimum macOS **26.0**. Tests ran on **macOS 27.0.1**. Previous uncommitted UI/navigation/search work was retained. No commit, push or remote repository creation was performed.

## Measured bottleneck

The opening path awaited a full snapshot, automatic-stash recovery, remote configuration, reference organization, Undo/Rebase state, Worktree/submodule inspection and Git Flow state before releasing the picker/busy state. Instrumenting the existing path showed 35 local Git subprocesses for the benchmark repository, with many tiny commands taking approximately 100 ms each. The remote configuration path performed one `remote` read plus three serialized config reads per remote. Initial snapshot also counted every reachable commit even though the UI uses a bounded history page.

The largest shared overhead was the process exit wait path: polling `isRunning`, followed by `waitUntilExit` and its Foundation run-loop waiting. Replacing that path alone reduced the same benchmark's median from 2.979 s to 0.395 s while retaining all 35 commands and all loaded features. The final batch-config/bounded-count adjustments reduced it to 0.228 s with 26 commands.

## Before / after

Fixture: **10,000 commits, 150 additional branches, 2,000 untracked files, 9 Worktrees and 3 remotes**. Each sample used a fresh RepositoryWorkspace/RepositoryStore and real Git processes against the same generated local repository. Three samples per implementation; medians below. All fixtures, including Worktrees, were deleted afterward. Remote addresses use example.invalid and were read as configuration only; the benchmark made no network request.

| Phase | Before (ms) | Final (ms) |
| --- | ---: | ---: |
| Entire workspace open → data ready | 2978.6 | 228.3 |
| Basic snapshot | 510.8 | 73.7 |
| Remote configuration | 1008.7 | 18.1 |
| Undo availability | 396.0 | 35.5 |
| Worktrees / submodules | 326.6 | 31.2 |
| Git Flow | 299.4 | 29.0 |
| Working-file presentation | 15.9 | 6.4 |
| Git subprocesses per open | 35 | 26 |

Total reduction: **92.3%**, approximately **13× faster** for this fixture. Phase medians are independent and should not be added to reconstruct the whole-open median. The outer workspace validation call, state publication and library writes are included in whole-open wall time. These are data-readiness measurements without a hosted UI; they are not foreground first-paint or OS cold-cache measurements, nor a claim that every personal repository opens in 0.228 s.

## Implementation

- GitProcess waits on a termination notification. Cancellable reads use short interruptible semaphore waits; noncancellable writes still finish the current step. Timeout/terminate/kill handling, file-backed stdout/stderr, output limits and error status handling remain.
- Remote configuration uses one multi-value config read after listing remote names. URL ordering, push-URL fallback, fetch refspecs, included configuration, dotted/case-sensitive names and empty values retain their behavior.
- Initial open passes `countHistory: false`. It retains the bounded commit page and marks a truncated count as inexact. Other snapshot callers keep the previous exact-count default; paged History and its existing cache continue normally.
- Recovery state, Worktrees, submodules and Git Flow still load before open finishes. No feature is hidden or silently omitted to obtain the measurement.
- RepositoryOpen timing uses one structured OSLog event per open with named phase durations and success status. Opt-in TaskLocal command tracing records only command verbs, phase labels, durations and failure flags; no arguments, paths, URLs, identities or command output are recorded.

## Verification

| Check | Result |
| --- | --- |
| Before and event-only benchmark | 1 passed each |
| Focused final benchmark + read/timeout/cancellation cases | 5 passed |
| Complete GitCore target | 212 passed, 0 failed |
| Complete App target except contention-sensitive LFS case | 107 passed, 9 opt-in checks skipped, 0 failed |
| Native offscreen render + separate LFS case | 2 passed |
| Final packaged basic background verifier | Passed, inactive, 0 visible windows |
| Final packaged real-App/menu verifier | Passed, inactive, 0 visible windows |
| Signature and whitespace checks | Passed |

Counts use test definitions from xcresult, excluding parameterized invocation expansion. The focused checks overlap the full suites and should not be added as unique test counts. The open benchmark and native renderer were explicitly enabled in separate runs; unrelated opt-in captures/benchmarks remained disabled.

Focused tests cover inherited/multi-value remote configuration, bounded/exact history counts, expected nonzero statuses, output limits, timeout recovery, prelaunch read cancellation and noncancellable write completion after cancellation. Full regression exercises staging/commit, branch checkout, stash/merge/recovery, nested Worktree/submodule migration and stale session guards. Git write acceptance used disposable repositories.

The real-App verification opened a separate empty temporary repository with a hosted, presentation-suppressed native window. Its recorded opening phase total was **0.428 s**, including native-host observation/update overhead; it is distinct from the unhosted benchmark. The native menu report confirms repository reuse, New Tab/Close Tab, Find and Quick Actions routing. Both launch verifiers recorded a foreground process different from GitPico.

OSLog events were observed in the focused test process output under category `RepositoryOpen`; phase data is also present in the real-App JSON. Source hashes, raw before/event/final samples, summaries, logs, native captures, bundle metadata and launch reports are under [evidence/repository-open-performance](evidence/repository-open-performance/).

No foreground mouse, active-window rendering, personal-repository timing or macOS 26 runtime acceptance was performed. Existing inactive-material rendering artifacts and the unrelated UTType export runtime warning remain outside this change.
