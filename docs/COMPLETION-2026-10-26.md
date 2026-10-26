# Git client completion — 2026-10-26

Scope: the six remaining areas in the latest maturity assessment. Keep marketing version 0.01, minimum macOS 26.0 and background-only testing. Implementation, fixture verification, live service acceptance and distribution acceptance are distinct results.

## Work

- [ ] Fix macOS 26 arm64/Intel CI compilation and verify the saved Xcode project.
- [x] Commit templates, reusable identities, structured history search, fixup entry and signature verification.
- [x] Root/merge-aware interactive rebase, structural conflicts and structural patch handling.
- [x] Fork review creation and inline review threads (GitHub resolve state remains on the hosting website).
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
- Final complete regression and additional light/dark offscreen captures are pending. CI and notarization results will be appended after execution.

## Publisher provenance

The user selected their personal developer team. ASC profile `Mac mini` returned Developer ID certificate serial `39F5726D8327AC07`, matching the installed `Developer ID Application: yanke li (NT9VR9C9HY)` certificate; its Notary API history was readable. The similarly named default account-holder API profile failed certificate authentication and was not substituted. `Configuration/Distribution.json` records only nonsecret defaults. GitPico's dedicated Sparkle key was generated in Keychain; only its 32-byte public verification key is committed.
