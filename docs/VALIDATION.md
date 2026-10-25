# Validation — 2026-10-23

## Environment and artifact

- Native Swift/SwiftUI application, SwiftPM executable + GitCore module.
- Build/interactive host: macOS 27.0.1, Apple Silicon.
- Required deployment target: macOS 26.0, configured in both `Package.swift` and the generated app `Info.plist`.
- `xcrun vtool -show-build dist/GitPico.app/Contents/MacOS/GitPico` reported `platform MACOS`, `minos 26.0`.
- `codesign --verify --strict --verbose=2 dist/GitPico.app` passed. This is local ad-hoc signing, not a distribution/notarization result.
- Entrypoint: `./script/build_and_run.sh`; Codex Run action points to it.

## Automated checks

`swift test` passed **12 Swift Testing tests**, with **0 failures**. The XCTest wrapper reports zero XCTest cases; the Swift Testing results at the end of the log are the actual test count.

Coverage:

- NUL-delimited porcelain parsing, spaces, Unicode/newline names and rename pairs.
- First commit in an unborn repository; unstage after additional edits without losing working-file content.
- Tracked files with staged and unstaged changes; literal pathspec handling.
- Staged rename, unstage, commit and deletion.
- Branch creation/checkout, tags, ref-scoped history, two-parent merge graph and first-parent merge diffs.
- Refused checkout preserving dirty work.
- Conflict detection and commit refusal.
- Stash tracked/untracked round trip, retaining the stash, excluding stash implementation commits from normal history.
- Nested directory root resolution and linked worktrees.
- Fetch, fast-forward pull and push against a disposable local bare remote; ahead count before/after push.
- Diff line numbering and preview limits.
- Empty commits/messages and non-repository errors.

Log: [swift-test.log](evidence/swift-test.log).

## Interactive verification

The installed Tower 18.0 was read through native accessibility and screenshots, including its Working Copy and History screens. No original app assets or source were copied. The reference repository was not mutated.

GitPico was launched as `dist/GitPico.app` and exercised through native controls against **only** `dist/PicoDemo`:

1. Selected a working file and inspected a real, colored Git diff.
2. Staged README, verified it entered the Git index; unstaged it; staged it again and verified the checkbox/state updated.
3. Entered a subject and created commit `d415381` (`Verify native staging workflow`). The form cleared and the committed files left Working Copy.
4. Opened History and inspected that commit's message, two changed files and diff.
5. Created and checked out `feature/ui-verified` through the native branch sheet; the HEAD badge and title updated.
6. Opened the native repository picker, navigated directly to PicoDemo and reopened it.

Screenshot: [history.png](evidence/history.png).

## Regressions found and repaired

- Apple Git 2.54.0 left untracked files behind after `stash push --include-untracked` when global literal-pathspec mode was enabled. Reproduced independently; literal mode now applies only to filename-bearing commands. The stash integration test verifies a clean worktree and successful reapplication.
- SwiftUI reused a moved working-file row with stale stage/button state. File rows now own their observation and use separate index/worktree identities. Verified by staging, unstaging and restaging in the UI.
- Short diff content was vertically centered in a two-axis scroll view. The preview now fills the viewport and anchors at the top.
- Recent repository history did not survive a rebuilt-app restart through default preferences. It now uses an atomic JSON file in the user's GitPico Application Support directory. The independent restart check is recorded below.
- Activation-triggered refresh could briefly block the first navigation/open action. Removed that competing refresh; repository actions refresh automatically and external changes use `⌘R`.

## Restart check

After opening PicoDemo, rebuilt and relaunched using `./script/build_and_run.sh --verify` **without** `--repository`. Native window state showed PicoDemo on `feature/ui-verified`, with one untracked file. The atomic Application Support history therefore survived termination/relaunch and restored the working directory.

## Limits

- macOS 26 runtime execution is not verified; the available host is macOS 27.0.1.
- Real GitHub/GitLab/SSH/credential/signing workflows are not verified. Remote operations were tested with a local bare repository.
- This is an initial functional implementation, not feature or pixel parity with Tower. History uses 500-commit windows; full-history paging is not implemented.
- Dark appearance was visually inspected. Light appearance, VoiceOver, large-repository performance and distribution are not yet audited.
- Advanced operations and remaining design work are tracked in [ROADMAP.md](ROADMAP.md).
- Source remains uncommitted and has not been pushed or published.
