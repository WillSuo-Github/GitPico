# Unified toolbar search — 2026-10-25

Packaged build: **0.01 / 20261025223258**. Deployment target stays **macOS 26.0**; all checks ran on **macOS 27.0.1**. Existing uncommitted navigation/UI work was preserved. No repository commit, push or remote repository creation was performed.

## Behavior

The wand Quick Actions toolbar button and separate QuickActionsSheet are removed. One native NSSearchField retains current-page filtering and presents matching files/File History, branches/references, commits and operations in an anchored suggestion panel. The field is also available on repository views without their own page filter.

- Ordinary text filters the current view live. Its first suggestion is the current-page filter; default Return keeps that filter and cannot execute a matching operation.
- Down/Up selects a result; Return or a result click executes it through the existing QuickAction dispatcher. Up from the first result returns to the page filter. Clicking the page-filter row cannot execute a previously selected operation.
- `⌘⇧A` or a leading `>` enters Quick Actions without changing the page filter. `⌘F` returns to page-search mode. Escape dismisses suggestions and restores the page query when leaving action mode.
- Destructive actions retain their existing review sheets. Submissions are de-duplicated; delayed execution checks the repository token and availability again. New text invalidates old selections; late index/hash lookup results cannot replace current results.
- File entries are indexed once per repository token/data-refresh/ignored-file-visibility state. Matching and file-item construction run off the main actor, with a 90 ms query debounce. Reopening the field reuses the index.
- SwiftUI owns the search/query/action state. The AppKit bridge owns native text/IME delegation and a nonactivating child panel. It closes on focus loss, outside clicks, app deactivation and teardown; its frame follows the parent window and search field. It never presents for inactive, hidden or presentation-suppressed windows.

## Background checks

| Check | Result |
| --- | --- |
| Native Xcode build-for-testing | Passed |
| Focused integration/keyboard/cache/race/native-render checks | 10 passed |
| Final native suggestion capture + context-row regression | 2 passed |
| Complete App target excluding contention-sensitive LFS check | 107 passed, 8 opt-in checks skipped, 0 failed |
| LFS state test run separately | 1 passed |
| Final packaged basic background verifier | Passed, inactive, 0 visible windows |
| Final packaged actual-App/menu verifier | Passed, Find and Quick Actions both update the same toolbar field, inactive, 0 visible windows |
| Bundle signature verification and diff whitespace | Passed |

The full App count is the test-definition count from xcresult; its parameterized execution count is 110. The focused and capture runs overlap other checks and should not be added together. Two skipped opt-in render checks were explicitly exercised in the capture/focused runs; the remaining unrelated opt-in capture/benchmark checks were not enabled.

Git write fixtures were disposable local repositories. The two staged-app verifiers recorded a different foreground process from GitPico. The actual menu verifier also retained the existing single-tab chooser and explicit New Tab / Close Tab behavior.

## Visual evidence and limits

Evidence lives in [evidence/unified-search](evidence/unified-search/): test summaries/logs, build log, bundle metadata, source hashes, native toolbar light/dark captures and suggestion-list light/dark captures. At 1440 points the native toolbar has 15 visible controls, including the search field, and no wand button.

The first ImageRenderer attempt omitted ScrollView content. The final suggestion images were recaptured from a suppressed native NSHostingView and inspected: the filter row, clean-file/File History matches and selected action rows render in both themes. No foreground window or live mouse/input-method session was used. Delegate tests cover marked-text deferral, arrows, Return and Escape; real active-window anchoring, mouse selection, assistive input and macOS 26 runtime acceptance remain unverified. Native full-window offscreen captures retain the existing inactive-material sidebar artifact; no overall design-parity verdict is claimed.
