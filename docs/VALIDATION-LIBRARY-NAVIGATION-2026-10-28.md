# Library and repository navigation — 2026-10-28

## Behavior

- Back and Forward traverse the repository library as well as repository visits.
  Opening the first repository records the initial library; choosing Repositories,
  creating a chooser tab, selecting a chooser tab, or closing the last repository
  also records the library. Repeated visits to the same destination are deduplicated.
- Going back from a repository to the library keeps the same native window and
  underlying repository store. Going forward reuses the loaded repository, preserving
  its draft, page, selected commit and existing history cache without a reload.
- A path such as Library → A → Library → B can be traversed in either direction.
  A new successful visit after going back clears the forward stack. Failed opens
  and busy operations do not consume history. Repository pages and individual
  commits remain outside this workspace-level history.
- Session history encodes existing repository paths as before, with an explicit
  `library` destination. Older path-only sessions still decode. On restore, a
  chooser that formerly pointed at a repository in history records its visible
  library destination, allowing Back to recover that repository.
- History validation still rejects relative paths, NUL bytes and more than 100
  total back/forward entries. Toolbar and Navigate menu labels now use Back/Forward;
  the new Forward String Catalog entry covers all 37 additional shipping locales.

## Validation scope

Tests use disposable local repositories and temporary library/session files.
Native windows run with presentation disabled; the application is not activated.
No foreground mouse/keyboard acceptance or installation replacement is claimed.
Host: macOS 27.2, arm64, Xcode 27.1. Minimum deployment remains macOS 26.0;
this is not macOS 26 runtime acceptance.

- Focused SwiftPM serial rerun: 11 navigation functions passed, zero failures/skips.
  Log: `/tmp/gitpico-library-navigation-final-tests.log`.
- Localization validator: 836 Core and 1772 app prose keys, 37 additional languages,
  zero errors.
- An exploratory full serial SwiftPM run passed all 257 Core functions, but the app
  target crashed in `BranchSyncBadgeTests.swift:68` when dereferencing `NSApp` before
  an application singleton existed. That test contains no workspace-navigation
  calls. The standard Xcode app-hosted suite is the full-app acceptance entry point.
  SwiftPM log: `/tmp/gitpico-library-full-tests.log`.
- Full native Xcode scheme, serial execution: 450 test functions total,
  428 passed, 22 conditional skips, zero failures. Parameterized cases are counted
  separately by the device-level summary (446 passed case runs).
  Result: `.build/xcode/Logs/Test/Test-GitPico-2026.10.28_19-34-01-+0800.xcresult`.
  Log: `/tmp/gitpico-library-native-full-tests.log`.
  This includes the native branch-badge test that requires the app host, all new
  library-history cases, existing workspace/draft tests, picker typing and native
  window/tab tests.

- `./script/build_and_run.sh --verify`: build/signature validation, background
  launch and native startup/menu/tab checks passed. Both reports record zero
  visible windows and `isActive = false`; repository menu reuse and native
  selection synchronization passed.
  Log: `/tmp/gitpico-library-startup-verify.log`.
  Reports: `dist/background-verification.json` and
  `dist/native-startup-verification.json`.
- `git diff --check`: passed. The generated Xcode project, source Info.plist,
  marketing version and deployment target were not changed.

This validation was captured before release preparation. Distribution and
publication evidence is recorded separately with the date-stamped release build.
No `/Applications` installation replacement was performed during validation.
