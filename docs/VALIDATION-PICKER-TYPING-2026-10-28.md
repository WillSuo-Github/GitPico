# Repository picker type-to-search — 2026-10-28

## Behavior

- Typing a letter or digit while browsing the repository picker focuses its search field,
  forwards the original key event exactly once and retains the initiating character.
  When returning from the list, new text appends to the existing query.
- Subsequent input uses the native field editor and updates the existing name/path/group
  filtering. Return submits only committed text.
- Command, Control, Option and Fn shortcuts, navigation/control keys, existing text editors,
  disabled/hidden search fields and other windows are not redirected. Attached sheets and
  modal windows are excluded. Initial focus also yields to an existing editor.
- Registration is weak, scoped to the owning repository window and removed when the picker
  field leaves that window. No global keyboard monitor is installed.
- Native marked text is retained during model updates and only committed input is published.
  Search field alignment follows the interface's writing direction.

## Evidence

Host: macOS 27.2, arm64, Xcode 27.1. Minimum deployment remains macOS 26.0;
this does not establish macOS 26 runtime acceptance.

- SwiftPM: four picker test functions passed, including both LTR/RTL page cases.
- Native Xcode: five focused functions passed, zero failures/skips, including native window
  tab/selection regression. Result:
  `.build/xcode/Logs/Test/Test-GitPico-2026.10.28_16-48-15-+0800.xcresult`.
- The page test moves focus away from search, sends `B`, `e`, `t`, `a` through the real
  `RepositoryNativeWindow.sendEvent` path and verifies query `Beta`, a single matching
  repository and the active field editor. Offscreen LTR/RTL captures were inspected.
- Marked-text/commit and Return behavior are exercised through native text APIs. A recording
  field-editor double observes forwarded key events without changing the user's input source.
  Physical input methods and candidate windows were not operated in the foreground.
- `./script/build_and_run.sh --verify`: build/signature, background launch and native startup
  checks passed with zero visible windows and no activation.
- Localization catalog validation and `git diff --check`: passed; no new translation keys.

Logs: `/tmp/gitpico-picker-tests-final.log`, `/tmp/gitpico-picker-native-final.log`,
`/tmp/gitpico-picker-final-verify.log`. Captures: `/tmp/gitpico-picker-typing.png` and
`/tmp/gitpico-picker-typing.rtl.png`. Fixtures use temporary library directories.
