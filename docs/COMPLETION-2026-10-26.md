# Git client completion — 2026-10-26

Scope: the six remaining areas in the latest maturity assessment. Keep marketing version 0.01 and minimum macOS 26.0. Foreground acceptance was explicitly authorized for this round. Implementation, fixture verification, live service acceptance and distribution acceptance are distinct results.

## Work

- [ ] Fix macOS 26 arm64/Intel CI compilation and verify the saved Xcode project.
- [x] Commit templates, reusable identities, structured history search, fixup entry and signature verification.
- [x] Root/merge-aware interactive rebase, structural conflicts and structural patch handling.
- [x] Simplify hosted collaboration to browser links. The user explicitly removed native PR/MR creation, comments, discussions and merge; its API client, sheets and optional API authorization were deleted.
- [x] Add repeatable reliability/performance checks for refresh, persistence and repeated sessions; physical long-running acceptance remains external.
- [ ] Validate signing/update prerequisites and distribution tooling; record external acceptance requirements.
- [ ] Reconcile current README/roadmap/parity claims and record exact final validation.

## Acceptance still requiring external evidence

Do not infer macOS 26/Intel runtime acceptance from the current host, real IME/VoiceOver from suppressed screenshots, production update acceptance from scripts, or service permission acceptance from mock HTTP. Existing grants and publisher credentials may be inspected without exporting secrets. Personal repository/server acceptance writes and foreground testing retain their explicit authorization requirements.

## Validation in progress

- Xcode build-for-testing passed on macOS 27.0.1 arm64 / Xcode 27.1. Minimum OS remains 26.0 and marketing version remains 0.01.
- First 16 focused workflow checks passed after correcting the literal-path query and temporary-directory storage check. Actual temporary SSH signing keys verify commit/tag results; no user's SSH keys or agent were changed.
- First complete run: 405 total, 391 passed, 1 failed, 13 skipped. The failure was the previous blanket symlink-patch rejection assertion, superseded by explicit symbolic-link support. The test now verifies that symlink-parent traversal cannot write outside the repository. The original failed result is retained in `.build/CompletionRegression.xcresult`; it is not reported as a green suite.
- That run also exercised 40 repeated two-repository session/draft/save/refresh rounds, simulated sleep/wake reconciliation, and bounded performance fixtures. Open median 231.84 ms; history preview median 15.18 ms; 500-file detail-task median 61.51 ms and maximum observed main-actor heartbeat gap 53.28 ms. These are background fixture measurements, not foreground FPS or long-duration energy acceptance.
- Subsequent full core run passed all 251 tests. The app run initially found a test selecting a path before its asynchronous file list was ready; after waiting for row readiness, all 155 app tests passed with the 40-round stress enabled. Twelve focused publication/OAuth checks and six native-window/API/publication checks passed afterward. These results predate removal of hosted review management; a new simplified-source full run is in progress.
- macOS 26 arm64 passed for commit `1af7d39` and again for `5061c47`. Intel run `40338284182` timed out after 40 minutes after reaching native session restoration; it is retained as a timeout, not a pass. Membership KVO now defers AppKit layout changes until the callback returns, and CI records bounded test-execution timeouts. The replacement Intel run remains pending.
- Universal Developer ID builds `20261026223241`, `20261026225000` and `20261026231503` received Accepted notarization and passed stapling/Gatekeeper. Their manifests bind source commits and SHA-256. Archive/feed validation accepted valid signatures and rejected tampering. These packages predate the user's scope reduction; they are not the final simplified build or proof of an actual update/install/relaunch loop.
- The private draft publisher originally hit a 404 querying a newly created draft by tag after ZIP upload. It now selects one exact owned draft from paginated authenticated release listings and refuses missing/duplicate/published matches. Nine Python packaging tests pass.
- Native local acceptance committed only the selected first hunk with a Chinese pasted subject, leaving the second hunk and unrelated edits intact. Actual Pinyin composition did not produce candidates and remains unverified. Saved Chinese template creation passed. No audible VoiceOver, physical sleep/display changes or long-duration soak was performed.

## Publisher provenance

The user selected their personal developer team. ASC profile `Mac mini` returned Developer ID certificate serial `39F5726D8327AC07`, matching the installed `Developer ID Application: yanke li (NT9VR9C9HY)` certificate; its Notary API history was readable. The similarly named default account-holder API profile failed certificate authentication and was not substituted. `Configuration/Distribution.json` records only nonsecret defaults. GitPico's dedicated Sparkle key was generated in Keychain; only its 32-byte public verification key is committed.

## Scope correction and retained service fixtures

The user explicitly rejected in-app PR/MR creation as unnecessary complexity. Native creation, files/checks/comments/feedback/merge, inline threads and their hosting write API were removed. Sidebar and Repository menu links open the hosting website without API authentication. GitLab sign-in requests only `read_user write_repository`; legacy saved configuration still decodes without re-requesting `api`. The GitLab OAuth registration was restored to those basic scopes. Changing registration is not claimed to revoke every previously issued server token.

Before this correction, the user-authorized synthetic GitHub PR #1 and GitLab MR #1 were both created and merged through GitPico OAuth. Both retain their synthetic file, ordinary comment, line-2 comment and reply; GitLab discussion resolution was re-read as Resolved. GitHub additionally exercised close/reopen. These are historical service evidence, not features in the final product. No further review writes are needed.
