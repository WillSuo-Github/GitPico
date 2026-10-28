# All Repositories drag reordering — 2026-10-28

## Behavior

- All Repositories uses native SwiftUI List row moving with an insertion position.
  The existing saved-library array is the manual order; no new storage format,
  custom drag type, permanent handle or separate sort mode is introduced.
- Reordering writes immediately through the library's existing atomic storage,
  external-change checks and writer lock. Reloading the library retains the order.
- Reordering preserves repository IDs, paths, names, groups, favorites, timestamps
  and Recent history. Opening an existing repository does not change manual order.
- Search results can be reordered within their visible slots; hidden repositories
  keep their positions. Recent retains its recent-open ordering. Other collections
  do not advertise this new picker move action.
- Captured row IDs are revalidated before saving. A query/filter change or a busy
  repository operation cancels the pending move. Invalid indices, duplicate/missing
  IDs, stale order and externally changed storage are rejected without overwriting
  the library. Selection remains attached to the repository ID.

## Evidence

Host: macOS 27.2, arm64, Xcode 27.1. Minimum deployment remains macOS 26.0;
this is not macOS 26 runtime acceptance.

- SwiftPM focused validation: 23 functions passed, including library metadata,
  persistence and write protections, native picker reordering, action guards,
  typing/search and library navigation regressions.
  Log: `/tmp/gitpico-library-reorder-final-tests.log`.
- Final native Xcode validation: 24 functions passed, zero failures/skips, including
  native window/tab and home/repository navigation regressions.
  Result: `.build/xcode/Logs/Test/Test-GitPico-2026.10.28_20-26-21-+0800.xcresult`.
  Log: `/tmp/gitpico-library-reorder-native-tests.log`.
- The native picker test obtains the hosted List's NSOutlineView and uses its
  public pasteboard-writer, session-begin, drop-validation and drop-accept callbacks.
  Moving Gamma before Alpha changes the displayed/saved order to Gamma, Alpha, Beta,
  preserves Gamma selection, and leaves the repository unopened. The screenshot
  `/tmp/gitpico-picker-reordered.png` was inspected.
- Drag information and the dragging session are test doubles. No foreground mouse
  operation or OS drag session is started. Native window presentation is suppressed,
  and the test asserts zero visible windows and no activation.
- Store coverage includes moves to both ends, nonadjacent multi-row moves, filtered
  results, no-op moves, restart/reload and invalid/stale/external-write rejection.
- Localization validation: 836 Core and 1772 app prose keys across 37 additional
  languages, zero errors. No new translation keys were introduced.

- `./script/build_and_run.sh --verify`: native build/signature, background launch
  and startup/menu/tab checks passed, with zero visible windows and no activation.
  Log: `/tmp/gitpico-library-reorder-startup.log`.
- `git diff --check`: passed.

This release batch also removes the duplicate Back to Repository toolbar button.
Its native toolbar captures and three related tests were checked separately; the
final native test selection above also covers window and navigation behavior.

Validation was captured before release preparation. Distribution and publication
evidence is recorded separately with the date-stamped release build. No
`/Applications` installation replacement was performed during validation.
