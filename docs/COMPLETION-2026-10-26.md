# Git client completion — 2026-10-26

Scope: the six remaining areas in the latest maturity assessment. Keep marketing version 0.01 and minimum macOS 26.0. Foreground acceptance was explicitly authorized for this round. Implementation, fixture verification, live service acceptance and distribution acceptance are distinct results.

## Work

- [ ] Fix macOS 26 arm64/Intel CI compilation and verify the saved Xcode project.
- [x] Commit templates, reusable identities, structured history search, fixup entry and signature verification.
- [x] Root/merge-aware interactive rebase, structural conflicts and structural patch handling.
- [x] Simplify hosted collaboration to browser links. The user explicitly removed native PR/MR creation, comments, discussions and merge; its API client, sheets and optional API authorization were deleted.
- [x] Add repeatable reliability/performance checks for refresh, persistence and repeated sessions; physical long-running acceptance remains external.
- [x] Validate signing/update prerequisites and distribution tooling; actual published update/install/relaunch remains an acceptance gate.
- [x] Reconcile current README/roadmap/parity scope and preserve exact validation results.

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

## Simplified product validation

- Source `543b06d`: `.build/CompletionSimplifiedRegression.xcresult` passed **403 test definitions: 386 passed, 17 intentionally skipped, 0 failed**. Core log reports 247 definitions and App log 156; parameter expansions are not added to the headline definition count. The opt-in stress/performance/capture/Keychain cases were skipped in this invocation. Prior stress/performance results remain separate evidence. [Result summary](evidence/completion-2026-10-26/simplified-regression.json).
- That run reported an existing undeclared exported drag UTI. `Configuration/GitPico-Info.plist` now exports `com.willsuo.GitPico.drag` conforming to `public.data`; the built bundle preserves marketing `0.01` and minimum `26.0`. All three drag-routing regression cases passed with no repeated UTI warning. [Focused result](evidence/completion-2026-10-26/drag-metadata-regression.json).
- CI now captures native process stacks and fails after 180 seconds without Swift Testing progress, in addition to Xcode's test limits. This preserves diagnosis if an AppKit hang prevents cooperative test timeouts. Newest macOS 26 arm64/Intel source acceptance is pending.
- Simplified universal build `20261026234538` received Accepted notarization (`cbf8712d-861c-4a46-924e-b5b0e577f2d3`), passed stapling and Gatekeeper, and launched from the dedicated `dist/CompletionInstall-20261026234538/GitPico.app` installation. Settings showed the actual build, its authentication page had no MR API controls, and its sidebar opened the default browser instead of an in-app review sheet. The provider redirected the private page to browser login; no CAPTCHA was completed. [Package provenance](evidence/completion-2026-10-26/signed-package-20261026234538.json).
- Before publication, native Check for Updates correctly displayed that no published readable release was available. Creating draft assets is not an accepted update loop. Publication remains a separate step.
- Re-generating a private appcast after editing its asset URL replaced that URL with a public download-prefix address. The publisher now signs the edited XML directly with `sign_update`, verifies its embedded feed signature and retains its exact authenticated resource ID before upload. The release ZIP signature is unchanged.
