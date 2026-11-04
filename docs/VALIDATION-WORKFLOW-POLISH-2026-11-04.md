# Workflow polish validation — 2026-11-04

## Scope

- Filter-aware, counted Stage Visible / Unstage Visible actions.
- Explicit current-view search scope, history filter form and literal changed-code queries.
- Code syntax coloring, inline changes, diff search and matching-line navigation.
- File History identity/header layout and older-history search affordance.
- Conflict branch/commit labels, focused source snippets, next/previous block navigation and native result-editor reveal.
- Native history multiple selection and reorderable batch Cherry-Pick/Revert.
- Reviewed branch cleanup and reversible bulk archive.

## Safety and boundaries

All Git acceptance writes use disposable local repositories. No personal repository or external server is used for acceptance writes. Tests and captures suppress windows and assert no application activation.

Batch operations use Git's sequencer and capture full commit hashes and HEAD. Duplicate/stale/dirty input is rejected before execution. Added destinations are checked for untracked or ignored content before the first commit. Conflicts retain the sequencer and original checkpoint across repository reopening; Continue/Abort and completed-operation Undo/Redo use the existing recovery routes.

Merge-containing batches apply one reviewed mainline parent number to all merge commits. A batch is capped at 200 commits. File History retains its existing 10,000-revision bound, and labels searches as loaded-revision searches.

Cleanup archives branch organization metadata without deleting refs or commits. It checks current tip, pinning and worktree occupancy again before writing. Missing tracking refers to local state after the latest fetch, not a live server check. Patch equivalence is advisory and may match a patch later reverted in the base; combined patches are searched within the last 200 first-parent commits. It is not a claim about a hosting provider's PR state.

Syntax highlighting is a bounded lexical aid for common source file extensions, not a compiler parser. Inline comparisons use bounded token differences with a single-span fallback for unusually long lines. Changed-code history search uses literal -S occurrence-count changes.

## Verification

Focused integration tests have passed for filtered staging, literal/quoted history queries, Unicode highlighting, native history multi-selection, native conflict-editor reveal/editing, batch ordering, batch Undo/Redo, stale/duplicate/dirty rejection, conflict Continue/Abort across reopening, squash-patch cleanup hints and stale-tip/pinned/current-branch archive protection.

Windowless light/dark gallery and feature-panel capture tests passed. Captures are available in /tmp/gitpico-polish-20261104/ during this session; accepted evidence will also be copied to the ignored docs/evidence/ directory.

Native Xcode full regression passed: 540 total, 510 passed, 30 opt-in/environment skips, zero failures. Result bundle: /tmp/GitPico-WorkflowPolish-20261104.xcresult.

Subsequent focused checks passed on the final refinements: four GitPico tests and thirteen GitCore tests, including native deselection, linked-worktree protection and a batch step committed in an external tool. Additional Cherry-Pick/Revert empty-step Skip cases and their batch Undo were verified.

The final native GitPico-target regression passed: 260 total, 231 passed, 29 opt-in/environment skips, zero failures. Result bundle: /tmp/GitPico-WorkflowPolish-FinalUI-20261104.xcresult. A final focused highlighting check also verifies that finding "+" searches displayed source operators, without counting Git's added-line prefixes as code matches.

The staged Debug app and actual native App/menu startup passed background verification with isActive=false and visibleWindows=0. Marketing version remains 0.0.1 and the minimum system remains 26.0.

Final development app: dist/GitPico.app, build 20261104165119. Both background verification reports match this bundle build and verify native tab/menu/search routing without activation. This development validation predates release packaging; release builds receive a new timestamp and retain their own source/signing/notarization manifest.

Syntax search highlighting is capped at 1,024 occurrences per line; matching-line navigation remains available. This avoids constructing unbounded attributed-text runs for generated/minified source.

## Captured evidence

Screenshots are offscreen renders. The sidebar's selected-row material is not accepted as foreground visual evidence; detail-pane crops and standalone panels are used here.

![Working-copy staging and diff](evidence/workflow-polish-20261104-working-detail.png)

![History filter form](evidence/workflow-polish-20261104-history-filters-light.png)

![File History header](evidence/workflow-polish-20261104-file-history-detail.png)

![Conflict navigation and source labels](evidence/workflow-polish-20261104-conflict-detail.png)

![Batch ordering preview](evidence/workflow-polish-20261104-batch-light.png)

![Branch cleanup review](evidence/workflow-polish-20261104-cleanup-light.png)

## Localization baseline

python3 script/validate_localizations.py currently reports 127 GitCore and 1,384 GitPico errors across 37 target languages. Comparing both catalogs with HEAD proves they are unchanged and the same errors predate this change. New UI text uses localizable source strings; translation coverage of these new strings is not claimed.

## Runtime acceptance limits

Foreground mouse/keyboard/IME/VoiceOver acceptance is not performed under the repository's background-only agreement. Offscreen AppKit/SwiftUI rendering does not establish live material/focus acceptance. Runtime execution on macOS 26 requires its own host; a newer host's build and tests do not replace it.
