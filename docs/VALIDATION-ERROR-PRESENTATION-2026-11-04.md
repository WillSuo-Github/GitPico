# Error presentation validation — 2026-11-04

## Scope

The supplied Push failure screenshot showed an unbounded alert filled with carriage-return transfer progress. `GitProcess` also read only the first 64 KiB of stderr, potentially discarding the final failure when progress exceeded that limit.

- Retain the last 64 KiB of stderr and indicate omitted earlier output.
- Present a redacted summary of at most 420 characters, preferring Git error/rejection lines and excluding recognized transfer progress.
- Offer Show Details and Copy Log from the alert. Capture details independently of the dismissed alert's live state.
- Display retained, redacted output in a fixed 640 × 460 pt details sheet with horizontal/vertical scrolling, initial position at the end, and persistent Copy Log/Close controls. Indicate when earlier output was omitted.

## Verification

- Host: macOS 27.2; deployment target remains macOS 26.0. This does not establish runtime acceptance on macOS 26.
- Disposable local transport fixture emitted over 100 KiB of progress before failing. Both the thrown failure and the network activity record retained its final diagnostic. No external remote was contacted.
- GitCore regression bundle: 283 passed, 1 skipped, 0 failed. Result: `/tmp/GitPico-ErrorPresentation-Full-20261104.xcresult`.
- The simultaneous full run had seven existing asynchronous UI deadline failures and an incorrect new size assertion that omitted the native title bar. Corrected the assertion and reran the UI bundle separately with parallel testing disabled: 235 passed, 29 skipped, 0 failed. See `/tmp/GitPico-ErrorPresentation-UI-20261104.xcresult` and `/tmp/gitpico-error-ui-summary.json`.
- New presentation cases cover carriage-return progress, final Git diagnostics, rejected refs, generic errors, empty/progress-only fallback, long Unicode messages, redaction, bounded layout and a scrollable oversized log.
- Suppressed native capture: `/tmp/gitpico-error-presentation-final/failure-light.png` and `failure-dark.png`. Inspected both captures; summary, final diagnostic and footer controls are visible. The test asserts its window is hidden and the app is inactive.
- `./script/build_and_run.sh --verify` passed with version `0.0.1`, build `20261104172236`. Both application and native startup reports show `isActive: false` and `visibleWindows: 0`; staged application: `dist/GitPico.app`.
- The initial filename-based test filter selected zero cases and is not counted as verification.

The saved network history inspected during this task had no matching Upovi failure. The screenshot does not establish why that Push failed. The Upovi repository was not modified or pushed during this investigation.
