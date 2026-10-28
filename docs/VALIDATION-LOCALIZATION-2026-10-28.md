# Localization validation — 2026-10-28

Build: `0.0.1 (20261028154450)`. Host: macOS 27.2, arm64; Xcode 27.1
(`27A9275`), Swift 6.4. The minimum deployment target remains macOS 26.0.
This is not runtime acceptance on macOS 26.

## Delivered behavior

- English plus 37 languages/regional variants declared in
  `Configuration/Localizations.json`, following the macOS per-application language.
- Two String Catalogs cover 836 GitCore prose keys and 1,771 app prose keys.
  All declared target languages have finished translations for every checked key;
  interpolation-only keys, symbols and Git status letters carry no translated prose.
- Shared controls carry localization resources. Complete interpolated messages replace
  sentence concatenation; 25 common count messages have plural variations.
- Stable identifiers and enum raw values remain separate from displayed titles.
  Quick Actions, operation history/status, file status help, menus, settings, warnings
  and errors use localized display text. Raw Git output, repository content and editable
  AI instructions retain their original language.
- App-owned errors resolve in the app catalog before becoming `GitFailure`; GitCore errors
  resolve in the framework catalog. AI diff-size handling uses a stable error reason.
- Arabic/Hebrew window roots, Settings and search suggestions follow RTL direction.
  Split dragging follows the pointer in either direction; paired diff headers and source
  columns retain matching LTR order. Conflict badges keep their stable status codes.
- Project generation registers every declared region despite synchronized source groups.
  String Catalog compilation canonicalizes Norwegian `no` to `nb`; runtime checks accept
  that alias while comparing the actual translated values.

## Evidence

- `python3 script/validate_localizations.py`: both catalogs, 37 target locales,
  **0 errors** after native compilation. Checks cover missing/unfinished translations,
  printf argument types/positions, percent escapes, newlines, cardinal plural categories
  and protected Git/product tokens.
- `python3 -m unittest discover -s script/tests`: **17 tests passed**.
- Final `swift test`: successful; the app and core runs reported 183 and 257 test functions,
  respectively. Existing opt-in live-service, capture, stress and performance cases retain
  their conditional skips.
- Final native `xcodebuild test -parallel-testing-enabled NO`: **418 passed,
  22 conditional skips, 0 failures**, including the native test-host check.
- `./script/build_and_run.sh --verify`: successful build, staged bundle signature,
  background launch, native startup/menu/tab checks. Both reports show `isActive=false`
  and `visibleWindows=0`.
- `python3 script/verify_localizations.py`: **38 configurations passed**, including
  English. Each launches its own suppressed app process and checks the selected language,
  app text, an app-owned error, GitCore status text, singular/plural output and absence of
  visible windows/activation. No system language preference is changed.
- Offscreen native captures of AI settings and Pull review were inspected in Simplified
  Chinese, German and Arabic. Arabic captures verify mirrored interface layout; German
  captures exercise longer text. No foreground mouse interaction was performed.
- `git diff --check`: passed.

The first default parallel native run failed six tests: network cancellation exceeded its
2-second threshold (2.074 seconds), a management lease was busy, and four asynchronous
repository/UI waits failed. All six passed in a focused run; complete serial runs passed
before and after the final display fixes. This batch does not establish reliability of the
default fully parallel native suite or claim a concurrency fix.

Final native result:
`.build/xcode/Logs/Test/Test-GitPico-2026.10.28_15-33-03-+0800.xcresult`.
Full logs: `/tmp/gp-l10n-full-swift-final.log`, `/tmp/gp-l10n-full-xcode-final.log`,
`/tmp/gp-l10n-final-native-verify.log`. Catalog/runtime summaries, the native result summary
and captures are copied to the ignored local directory
`dist/localization-validation-2026-10-28/`.

Coverage and format checks do not establish native-speaker review of every translation,
nor visual acceptance of every screen in all 38 configurations.
