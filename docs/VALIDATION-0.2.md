# Validation — GitPico 0.2 — 2026-10-23

## Reference and comparison

The installed Tower 18.0 was inspected through native accessibility and screenshots. Both applications opened `dist/PicoDemo`. Captures use the same 3840 × 2100 physical-pixel window size.

References:

- [Tower Working Copy](evidence/tower-working-reference.png)
- [Tower History](evidence/tower-history-reference.png)
- [Tower Branches Review](evidence/tower-branches-reference.png)

The content-list target widths were measured from Tower's native controls: Working Copy 310 points, History 320 points. GitPico's sidebar uses the observed 359-point width. Explicit SwiftUI split geometry keeps content-list widths stable when selections change and persists user adjustments.

This is a substantial functional and visual iteration, not pixel or feature parity. Tower's sample Branches Review showed zero ahead/behind while separately listing two unique commits. GitPico reports the actual Git ancestry result (2 ahead, 0 behind) rather than reproducing that inconsistency.

## Automated verification

`swift test`: **24 Swift Testing tests passed, zero failures**. One parameterized test exercises both rebase and cherry-pick conflict paths. The XCTest wrapper's zero-case line is not the Swift Testing count.

In addition to the initial suite, checks cover:

- Stage one of two separated chunks, verify only that chunk enters the index, and unstage it without changing the working file.
- Untracked-file chunk stage/unstage; stale diff refusal; preview limits and leading-plus content statistics.
- Amend/sign-off, full metadata and numstat parsing (including renamed and binary files).
- Page limits/total counts and full-body search for a commit outside the loaded page.
- Branch ahead/behind/unique commit calculations.
- Clean merge/rebase/cherry-pick, dirty-worktree refusal, and conflict abort/continue for all three operations.
- Init/clone without overwriting existing directories.
- Repository identity/description/signing configuration and shared/local ignore files, including refusing stale writes.

Log: [swift-test-v2.log](evidence/swift-test-v2.log).

## Native interaction checks

Performed only against PicoDemo; the user's original Costaware repository was not mutated:

- Selected a file in the compact native list; inspected chunk content and old/new line numbers.
- Clicked Stage Chunk and verified the row became added/staged and the view changed to Staged. Clicked Unstage Chunk and verified it returned to untracked/Unstaged with content retained.
- Expanded commit options, entered a draft, toggled Amend to load HEAD's subject, then canceled Amend and verified draft restoration without creating a commit.
- Adjusted the content-list width through its accessible Increment/Decrement actions and verified the numeric width changed 310 → 330 → 310 points.
- Opened History, inspected complete metadata/statistics and expanded all changed-file diffs.
- Searched for `friendly`, obtaining the older `Add a friendly greeting` commit and its actual changes.
- Loaded Branches Review against main; verified feature/polish and feature/ui-verified were 2 ahead/0 behind, and feature/welcome was merged (0 ahead/2 behind).

- Restarted without a repository argument. PicoDemo reopened, the adjusted 330-point Working Copy list width survived and Show Graph remained off. Restored the width to 310 points and Show Graph to on afterward.
- Enabled First Parent Only and scoped History to feature/ui-verified: six commits remained in one lane. Restored all-ref history and disabled the option: seven commits and the merged branch were visible again.
- Opened Tree and selected README.md; the historic file content matched the selected commit. Directory disclosure controls worked.
- Opened General settings and inspected the actual local identity, description and signing state. Ignores loaded the empty shared file; Excludes loaded the repository-local file and its existing comments. No sample settings or ignore rules were written.
- Opened Merge with feature/polish selected. The sheet showed the target hash and refused integration while the demo contained an untracked file. Canceled without mutating history.
- Compared final screenshots at the same window size. Major column boundaries and metadata structure align, while toolbar grouping, typography, row density and tied-date graph ordering still differ. History diffs now use seven context lines, matching the inspected Tower file preview.

Final captures: [Working Copy](evidence/working-v2.png), [History](evidence/history-v2.png), [Settings](evidence/settings-v2.png). The final [History accessibility snapshot](evidence/history-v2-ax.txt) contains seven commits and expanded file diffs.

Build/launch: [build-and-launch-v2.log](evidence/build-and-launch-v2.log). Binary deployment target: [deployment-target-v2.log](evidence/deployment-target-v2.log). Ad-hoc signature: [signature-v2.log](evidence/signature-v2.log). After the final context-line adjustment, three targeted history/metadata/tree tests also passed: [history-test-v2.log](evidence/history-test-v2.log).

## Failures found and repaired

- A provisional native split controller force-unwrapped an unavailable UserDefaults suite and crashed on startup. The crash report identified that exact initialization. Removed the force unwrap and provisional controller. Both preferences and widths now use an atomic Application Support JSON file; split geometry is SwiftUI-owned.
- The provisional split controller reset content widths during layout. Replaced it with explicit state-backed geometry and accessible width adjustment.
- An observable preference initializer saved partial state before all fields loaded, losing saved widths. Added a loading guard and verified persistence through a real application restart.
- Tracked/untracked diff-version transitions now select the valid staged/unstaged side after chunk operations.
- Commit decoration chips/date labels were constrained so they do not squeeze author names or wrap dates in compact content lists.
- Integration is blocked while an existing merge/rebase/cherry-pick is active. Conflicts surface the operation state and recovery controls.

## Verification limits

- Runtime host is macOS 27.0.1; deployment metadata remains macOS 26.0. No macOS 26 runtime claim is made.
- Authentication against hosted providers and production SSH/GPG signing are not verified. Remote tests use a disposable local bare repository.
- No comprehensive light-appearance, VoiceOver, high-volume repository or distribution audit has been completed.
- Outstanding features and remaining visual differences are listed in [ROADMAP.md](ROADMAP.md).
- Source remains uncommitted and unpushed.
