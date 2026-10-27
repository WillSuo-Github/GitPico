# Manual update feedback — 2026-10-27

Local build: `0.01 (20261027150028)`. Host: macOS 27.0.1 arm64. Deployment target remains macOS 26.0; no macOS 26 or Intel runtime acceptance is claimed.

## Finding and change

The menu previously awaited GitHub authentication, latest-release lookup and signed-feed URL resolution before calling Sparkle's interactive check. Preparation failures only changed the status text in Updates & Support. A manual menu click therefore had no immediate progress window and could fail without displaying an error.

Manual checks now show Sparkle's native progress UI before preparation, support cancellation, reject late results after cancellation, dismiss preparation UI before handing off to Sparkle, and display preparation failures immediately. Failure text identifies account authentication, release lookup or signed-feed resolution. Scheduled checks retain their quiet behavior. The menu explicitly binds to the update model and disables repeat requests during preparation. Existing Sparkle update/download sessions are brought forward through Sparkle instead of being replaced by preparation UI.

Local Xcode builds now load the repository's committed public key and GitHub feed configuration by default. An explicit empty public-key override still disables the defaults. The reported issue occurred with a GitHub Release build, whose update configuration was already complete; the local-build change addresses a separately observed configuration difference.

## Validation

- Four focused manual-flow tests passed: immediate progress and single handoff; account/network/private-release failure feedback; cancellation followed by retry with late-result rejection; cancellation without a false error.
- Two existing private-feed security tests passed, retaining authenticated asset-ID checks and trusted HTTPS CDN resolution.
- A Developer ID signed test host used the existing app account path, including OAuth credential refresh when needed, to read `build-20261027142132` and resolve its signed feed. The sanitized diagnosis reported success and one archive. No credentials or signed CDN URLs were recorded. This proves the current account/feed path works; it does not establish the exact error on the user's earlier click.
- Complete app-target regression: **150 passed, 20 conditional skips, 0 failures** (170 test functions; parameter cases are not counted again).
- Python metadata/packaging tests: **10 passed**.
- The local bundle includes the same committed update verification key and GitHub feed, passes strict code-signature verification, and uses the existing Developer ID identity to preserve the account-reading context.
- Native user-driver APIs were checked against the pinned Sparkle 2.10.1 source and [official user-driver documentation](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUserDriver.html).

Tests remained in the background without activation or visible windows. No foreground menu/mouse acceptance was performed. The existing GitHub Release was not replaced by this local fix.

Temporary evidence: `/tmp/gitpico-update-feedback-tests.log`, `/tmp/gitpico-update-feedback-signed-tests.log`, `/tmp/gitpico-update-account-diagnosis.json`, `/tmp/gitpico-update-feedback-regression.log`, `/tmp/gitpico-update-feedback-background.json`, `/tmp/gitpico-update-feedback-native-startup.json`.
