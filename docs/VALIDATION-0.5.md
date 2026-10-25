# GitPico 0.5 validation

Date: 2026-10-24. Host: macOS 27.0.1, Apple Silicon. Minimum supported platform remains macOS 26.0; a macOS 26 runtime was not available for this pass.

## Outcome

- Full `swift test`: **54 Swift Testing tests passed**, 63.893 seconds. [Log](evidence/swift-test-v5.log).
- The initial eight inspection/Revert tests passed after a real missing-blob failure was corrected. A ninth test for externally moved Revert preview heads was then added and passed in the full run. [Initial focused pass](evidence/inspection-tests-v5.log).
- SwiftPM app build, ad-hoc signing, normal app launch and process verification passed. [Build/launch](evidence/build-and-launch-v5.log), [signature](evidence/signature-v5.log), [Mach-O deployment target](evidence/deployment-target-v5.log).
- Bundle version 0.5.0 (5), LSMinimumSystemVersion 26.0, Mach-O minos 26.0. This is a development build, not a notarized distribution.
- No source commit, push or release was performed. The project remains an unborn Git repository with untracked source files.

## Automated Git workflows

Tests use disposable repositories with local identity, signing disabled and hooks isolated. New coverage in `FileInspectionTests.swift` verifies:

1. File history follows renames, preserves original paths and emits rename diffs. Newline/tab/Chinese filenames remain exact. Paging has a has-more result and a pinned immutable tip.
2. Literal bracket filenames do not match similarly named files. Deleted files remain visible in history; raw lookup at their deletion commit fails. Binary text inspection and escaping repository paths are rejected.
3. Blame preserves source tabs, empty files and missing final newlines; every line retains author, email, date, original path/line and commit hash across rename history.
4. Arbitrary revision comparisons produce the correct file set; merge-base mode excludes changes on the base side. Moving a branch afterward does not change the already captured comparison.
5. Rename comparisons include both original and destination paths, without presenting an artificial new file.
6. Revert creates a new commit, preserves original history and supports file-restoring Undo/Redo.
7. Revert conflicts can Abort or resolve/stage/Continue; completed conflict resolution enters the history journal and can be undone.
8. Reverting a merge requires an explicit valid mainline. Dirty worktrees are rejected.
9. Moving HEAD after the Revert preview invalidates the operation, preserving the external commit and repository state.

The full run also passes the previous line-staging, split-diff, conflict, interactive-rebase, history recovery and repository tests. It is not a new native UI walkthrough of every pre-existing screen.

### Defect found during testing

On the installed Apple Git, `git show HASH:literal[1].txt` can return success with empty output after the literal file was deleted. The test expected a missing-blob error and failed. New Raw/Blame and the pre-existing historic-tree raw lookup now use strict `git cat-file blob HASH:path` with commit resolution and relative-path validation. The focused and complete runs pass after the fix. Literal-pathspec mode was extended to `log` and `blame`, without enabling it for compound `stash` operations.

## Native application walkthrough

The first newly built app was exercised, then UI corrections were built and the relevant routes were rechecked. All writes were confined to a new `dist/InspectionReview-9_v01e1h` repository created with [the demo generator](../script/create_inspection_demo.py). The previous HistoryReview repository was inspected read-only and preserved.

1. Opened the new repository through the normal native Open panel. Repository > File History opens a tracked-file picker even when the working copy is clean.
2. Selected `App/Welcome.swift`. The list shows four commits, including its rename from `Sources/Welcome.swift`. Diff and Raw match the selected revision. The earliest revision uses its original path and displays spacing 12; the latest displays spacing 14 and the changed title. [Original-path AX evidence](evidence/file-history-original-path-ax-v5.txt).
3. Blame attributes line 1 to `3e5330aa`, line 2 to Maya's `4cdf331c`, and unchanged line 3 to the original `bf98bc58` / `Sources/Welcome.swift:3`. Clicking Maya's attribution opens the correct commit summary. [Final Blame AX](evidence/blame-native-ax-v5.txt).
4. Compared `review-base` (`62d71eaa`) to HEAD (`7927570d`): two added files, `App/Welcome.swift` (+3) and `Notes.md` (+1). Split diff displays the exact added lines. The merge-base checkbox and Compare action were exercised. Divergent-branch merge-base behavior is verified by the automated test.
5. Invoked Revert from the real commit context menu. The review sheet displays `7927570d`, its subject and branch. Revert produced `2328e672f5986330b6973ad19d10789b0949ce10` with subject `Revert "Add inspection notes"`; `Notes.md` disappeared and the working copy remained clean. [Git result](evidence/revert-native-result-v5.json).
6. Undo Revert restored `7927570d` and `Notes.md`, clean. [Undo result](evidence/revert-native-undo-v5.json). After an actual app rebuild/relaunch, Redo remained available and restored the Revert result. Undo restored the original demo again.
7. The final build updates the selected commit's ref decorations after Redo: the previously selected `7927570d` no longer claims HEAD/main after HEAD moves to `2328e672`. [Native AX evidence](evidence/revert-native-redo-ax-v5.txt).
8. The commit context menu's Compare action prefills the selected commit hash. History remains selected in the sidebar on file-history and comparison subpages. The duplicated Diff header/layout picker was removed and rechecked.

Final demo state: branch `main`, HEAD `7927570d05b65a65d78d9c99167e69049438c384`, clean; original notes restored. App left showing the latest file's Blame for inspection. Existing history/working-pane widths were preserved.

### Screenshots actually inspected

- [File history and split diff](evidence/parity-gitpico-file-history.png)
- [Blame with right-side attribution](evidence/parity-gitpico-blame.png)
- [Revision comparison](evidence/parity-gitpico-compare.png)
- [Revert preview](evidence/parity-gitpico-revert-preview.png)
- [Revert result](evidence/parity-gitpico-revert-result.png)

## Remaining boundaries

File history currently follows one pinned tip, not all refs simultaneously; loaded-history search is not a full-history server query. Paging loads 500 at a time up to 10,000. File restore/export, file-search autocomplete and full Tower revision navigation are missing. Raw/Blame require UTF-8 files up to 2 MB and share the 16 MB Git-output limit. Syntax coloring is not implemented. Binary/symlink/submodule inspection is not a complete Tower-equivalent viewer.

Comparisons cover committed trees; working-tree/index comparisons remain the existing Working Copy flow. External diff tools and multi-select compare are missing. Revert handles one commit at a time, including explicit merge mainline; a batch sequence UI is absent. Merge-mainline and conflict Reverts were tested through the GitCore integration tests, not a native conflict walkthrough in this pass.

Core history Undo/Redo now includes Revert, but still excludes staging, checkout, stash and discarded local edits. Text conflict drafts remain process-local. macOS 26 runtime, light mode, full VoiceOver/keyboard journeys, large-repository profiling, real hosting authentication/PRs and distribution validation remain outstanding.

The [98-unit Tower parity audit](TOWER-PARITY-2026-10-24.md) is the maintained backlog. Bundle strings and resources are only candidates until confirmed by native UI or official documentation; the audit does not claim to enumerate every hidden or server-controlled feature.
