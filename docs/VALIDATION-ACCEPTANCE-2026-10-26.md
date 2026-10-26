# Maturity acceptance — 2026-10-26

## Decision

**Partial acceptance. The app is not yet accepted as a complete, distribution-ready Git client.** Core local write safety, draft recovery and basic native navigation passed the cases below. Several requested capabilities are absent, and live OAuth acceptance exposed a crash that required a code correction.

This is an acceptance audit of the six maturity areas discussed with the user. Missing capabilities were inspected and recorded, rather than silently implemented as part of testing.

## Build and method

- Baseline: `b92ba430335e095e4cc3fd2953196fccbd25a975`, `main`.
- Initial staged app: **0.01 (20261026152411)**. Callback correction staged as **0.01 (20261026161052)**, with the two source/test files modified locally.
- Minimum OS: **26.0**. Actual host: **macOS 27.0.1 / arm64**. No macOS 26 or Intel runtime acceptance is implied.
- The user explicitly authorized foreground native acceptance for this task. Mouse/keyboard actions used the staged app; Git writes used disposable synthetic repositories under `dist/Acceptance-20261026-ml2ft350`.
- A private [GitHub acceptance repository](https://github.com/WillSuo-Github/gitpico-acceptance-20261026-ml2ft350) was created empty for private HTTPS testing, then populated with a synthetic commit through GitPico OAuth. Its creation through an existing CLI login does **not** validate GitPico OAuth. A separate private [GitLab acceptance repository](https://gitlab.com/willsuosuo/gitpico-acceptance-20261026-ml2ft350) was created through the logged-in website, then cloned and pushed through GitPico OAuth. Both cloud fixtures are retained for inspection. No personal project repository was used for acceptance writes.
- Hosted Xcode tests and live browser authorization must run serially. The first GitLab attempt overlapped tests and was initially suspected to be disturbed by them. A second, serialized attempt crashed identically; both crash stacks establish a product callback defect. The earlier attribution to test interference was premature.

## Acceptance matrix

| Area | Result | Evidence and practical limit |
| --- | --- | --- |
| Local review/staging/commit | Pass for exercised cases | Native first-hunk staging, Chinese commit subject, Command-Return commit; unstaged second hunk and unrelated files preserved. |
| Automatic refresh | Pass for exercised cases | External file edits appeared without pressing Refresh, including a Chinese filename and the selected diff's new content. |
| Conflict draft persistence and safety | Pass for exercised cases | Unsaved edited result recovered after normal quit/reopen; original conflict remained unstaged; stale external file/index state blocked saving. Crash-before-debounce durability is not established. |
| Actual OAuth and private HTTPS Git | Both providers basic flow passed; broader matrix partial | Both live accounts survived restart and passed Verify, private Push/Fetch and Test Remote. GitLab private Clone also passed. Real expiry/renewal/revocation remains unverified. |
| Native keyboard, IME, accessibility and compatibility | Partial | Open/New Tab, history selection and Command-Return exercised. Chinese paste and UTF-8 persistence passed. Actual Pinyin candidate composition, VoiceOver, macOS 26 and Intel remain unverified. |
| Large repository performance | Partial | 3,001 commits, 122 local branches, 500-file latest commit opened; six branch previews selected correctly without checkout. No frame-time trace or long-duration soak was captured. |
| Pull policy | Safety passed; capability missing | Divergent Pull refused safely, preserving HEAD and clean index/worktree. Pull exposes only `--ff-only`; merge/rebase choice and guided recovery are absent. |
| Workspace/tab session recovery | Not accepted | Two native tabs existed before quit. Relaunch showed the repository chooser, not the tab session. Commit/conflict drafts recovered when each repository was reopened. |
| Images/binary and broader review | Capability missing | Image and binary changes show a text/binary fallback, not image comparison. All-reference file history and remaining advanced review variants are not accepted by this audit. |
| Hosted PR/MR workflow | Capability missing | OAuth/account support does not provide PR/MR lists, creation, checks or review workflow. Existing documentation explicitly lists this work as outstanding. |
| Distribution and operations | Not ready | Staged app is ad-hoc signed, arm64 only, with no stapled ticket. No CI workflow or Sparkle/appcast files were found. Developer ID distribution, notarization, updates and upgrade Keychain trust remain unaccepted. |

## Native local evidence

1. [Repository picker](evidence/acceptance-2026-10-26/01-repository-picker.png) opened the synthetic Client fixture.
2. [Partial staging and Chinese subject](evidence/acceptance-2026-10-26/04-chinese-summary-and-partial-stage.png): [index assertions](evidence/acceptance-2026-10-26/native-chunk-stage.json) prove only the first hunk was staged. [Commit assertions](evidence/acceptance-2026-10-26/native-partial-commit.json) prove the Chinese subject persisted, the first hunk was committed and the second stayed in the working tree.
3. [Automatic external refresh](evidence/acceptance-2026-10-26/05-native-external-refresh.png) showed the new Chinese file path and updated selected diff after external writes.
4. [Image fallback](evidence/acceptance-2026-10-26/06-image-diff-fallback.png) shows the missing visual comparison. Binary.dat was also inspected and displayed the binary text fallback.
5. [Two tabs and unsaved conflict result](evidence/acceptance-2026-10-26/07-unsaved-conflict-draft-and-two-tabs.png), [chooser after restart](evidence/acceptance-2026-10-26/08-restart-did-not-restore-tabs.png), [recovered conflict draft](evidence/acceptance-2026-10-26/09-conflict-draft-restored.png), [archive assertions](evidence/acceptance-2026-10-26/conflict-restart.json), and [recovered commit draft](evidence/acceptance-2026-10-26/14-commit-draft-restored.png). This distinguishes draft recovery from missing workspace restoration.
6. [Stale result save refused](evidence/acceptance-2026-10-26/10-stale-conflict-save-blocked.png); [file/index assertions](evidence/acceptance-2026-10-26/conflict-stale-write-protection.json) confirm the external edit survived and the index did not change.
7. [Divergent Pull refusal](evidence/acceptance-2026-10-26/11-divergent-pull-refused.png) and [retained failed operation](evidence/acceptance-2026-10-26/12-failed-pull-in-network-activity.png). [Native post-state](evidence/acceptance-2026-10-26/native-pull-divergence.json) verifies HEAD unchanged, index semantically equal to HEAD, clean worktree and one commit ahead/behind. A byte-for-byte pre-index hash was captured for the separate CLI baseline, not the native step; these checks must not be conflated.
8. [Large branch preview](evidence/acceptance-2026-10-26/13-large-branch-preview.png), [interaction record](evidence/acceptance-2026-10-26/native-large-interactions.json), [fixture state](evidence/acceptance-2026-10-26/large-fixture-state.json). Previewing `branch-1`, then `branch-10` through `branch-14`, kept the checked-out branch at `main`. Automation round trips include input/accessibility overhead and are **not** rendering-latency measurements.

The network panel retained the failed Pull and raw Git guidance. Its app advice remained generic, without a direct merge/rebase recovery action. This is a usability gap even though write safety passed.

## Live OAuth findings and correction

### GitHub

The user personally approved GitPico's existing requested permissions. Safari displayed the provider's [device activation success](evidence/acceptance-2026-10-26/03-github-provider-activation-success.png), but [GitPico reported a network failure](evidence/acceptance-2026-10-26/02-github-native-network-failure.png) and did not save an account. A further start attempt failed the same way.

System diagnostics observed a TLS session failure (`NSURLErrorDomain -1200`, underlying `-9816`) through the configured local proxy at `127.0.0.1:7897`. This supports a transport problem in this environment; it does not establish which endpoint or proxy behavior caused it. Certificate validation and user proxy settings were not weakened or changed. Existing `gh` credentials were not substituted for GitPico OAuth.

A later serialized retry on build **20261026161052** obtained a new device challenge and completed successfully. The provider showed **Existing access** with the same personal-account permissions already approved by the user; no organization Grant/Request action was used. GitPico saved `WillSuo-Github · GitHub · OAuth` and Verify succeeded. After normal quit/reopen the account remained, and Verify succeeded again. The earlier TLS failures remain relevant intermittent-failure evidence; no proxy, TLS validation or transport retry policy was changed to obtain the passing retry.

For private Git writes, a second local synthetic repository was initialized with only `Acceptance.txt`, test identity and commit `34a37531a24a0be97086d26882dfb47f971ddf7c`. Its selected authentication profile was explicitly set to the saved GitHub OAuth account. Native Push, Fetch and Test Remote succeeded against the private GitHub fixture. Local HEAD, origin/main and the server's main commit matched; the working tree was clean with ahead/behind 0/0. The repository-local `push.autoSetupRemote=true` setting was used for the first push to the initially empty remote; this test does not accept the app's general first-publication onboarding.

The connected GitHub tool returned 404 for this private fixture, so existing `gh` CLI access was used only for read-only server visibility/commit confirmation. It confirmed `private=true` and the expected commit/file. CLI credentials were not used for the acceptance Push, Fetch or Test Remote operations.

Evidence: [account verified](evidence/acceptance-2026-10-26/21-github-oauth-account-verified.png), [verified after restart](evidence/acceptance-2026-10-26/23-github-oauth-verified-after-restart.png), [native Push/Fetch successes](evidence/acceptance-2026-10-26/24-github-oauth-push-fetch-succeeded.png), [Test Remote](evidence/acceptance-2026-10-26/25-github-test-remote-verified.png), [structured assertions and server confirmation](evidence/acceptance-2026-10-26/live-github-oauth.json). **GitHub's basic live login/persistence/private-read-write path passed on this host/build.** Expiry, renewal, revocation and organization-policy coverage remains unverified.


### GitLab

The user completed approval twice. Both attempts terminated in `_dispatch_assert_queue_fail` on Safari's XPC callback queue, through the closure in `OAuthBrowserSession.authenticate`. See [sanitized crash symbols](evidence/acceptance-2026-10-26/oauth-callback-crashes.json). The second reproduction occurred with no build/test process running.

The completion closure was created inside a MainActor-isolated method. Entering that implicitly isolated closure from the system's background queue asserted **before** the nested `Task { @MainActor in ... }` could perform its hop. The correction constructs a nonisolated, Sendable completion entry, then explicitly hops to MainActor for session state. Success and cancellation are covered by a background-queue regression test using that same bridge.

The corrected staged app was explicitly quit/reopened before its live retry. The user completed the same GitLab grant. The app then saved `willsuosuo · GitLab · OAuth`, and native Verify succeeded. After closing the sheet and a normal quit/reopen, the saved account remained and Verify succeeded again. No build/test ran alongside the live retry.

The private GitLab project **88095642** was created with an initial README. GitPico's Clone form explicitly selected the saved GitLab OAuth profile. Clone succeeded into `dist/Acceptance-20261026-ml2ft350/GitLabOAuth`. A synthetic `Acceptance.txt` was staged and committed through the native app using a repository-local test identity, then pushed through the same assigned OAuth profile. Fetch and Test Remote also succeeded. The server's project page displayed commit `e1ca67e840bef82016cfed29efafc41aa1be3263`, matching local HEAD and origin/main; the working tree was clean and ahead/behind was 0/0.

Evidence: [saved account](evidence/acceptance-2026-10-26/15-gitlab-oauth-account-saved.png), [Verify](evidence/acceptance-2026-10-26/16-gitlab-oauth-account-verified.png), [Verify after restart](evidence/acceptance-2026-10-26/17-gitlab-oauth-verified-after-restart.png), [private project](evidence/acceptance-2026-10-26/18-gitlab-private-fixture-created.png), [native Clone/Push/Fetch successes](evidence/acceptance-2026-10-26/19-gitlab-oauth-clone-push-fetch-succeeded.png), [server commit](evidence/acceptance-2026-10-26/20-gitlab-server-confirmed-push.png), [structured assertions](evidence/acceptance-2026-10-26/live-gitlab-oauth.json).

**GitLab's basic live login/persistence/private-read-write path passed on this host/build.** Real expiry/renewal, revocation, organization policies and upgrade Keychain trust are not established by this successful short test. No access or refresh token was exported for testing.

## Additional unresolved-upstream finding

The GitHub synthetic fixture initially preconfigured `branch.main.remote=origin` and `branch.main.merge=refs/heads/main` before the empty server had any main ref. Opening that fixture failed with `fatal: no such branch: 'HEAD...'`. Removing the premature tracking configuration allowed normal opening. This is a repository-open boundary failure, separate from OAuth; it remains uncorrected and must not be hidden by the later successful network operations. [Alert](evidence/acceptance-2026-10-26/22-missing-upstream-open-failure.png), [trigger and fixture adjustment](evidence/acceptance-2026-10-26/missing-upstream-open-failure.json). A repository with a configured but unresolved upstream should still open and offer a clear repair action.

## Automated checks

- Complete baseline run: `TEST_RUNNER_GITPICO_VERIFY_KEYCHAIN_HELPER=1 xcodebuild test -project GitPico.xcodeproj -scheme GitPico -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO`.
- Runner reported **228 Core tests**, 339.123 seconds, and **144 App tests**, 83.351 seconds, successful. It separately reported **13 opt-in skips**. These counts are test-runner summaries, not foreground journeys. [Regression summary](evidence/acceptance-2026-10-26/regression-summary.json).
- Post-correction selected run: **7 OAuth App tests passed**, 0.011 seconds, including the new real-background-queue completion bridge test. [Results and source hashes](evidence/acceptance-2026-10-26/oauth-callback-fix-tests.json). The initial file-name filter selected zero tests; it is not counted as validation. The subsequent function-name filters selected and executed all seven cases.
- The correction compiled and staged successfully. No full Core rerun was needed for the isolated AppKit callback bridge change. Full-app and live acceptance limits remain explicit above.
- Local verbose logs: `.build/acceptance-build-2026-10-26.log`, `.build/acceptance-regression-2026-10-26.log`, `.build/acceptance-oauth-fix-tests-selected.log`, `.build/acceptance-oauth-fixed-build.log`.
- [Release inspection](evidence/acceptance-2026-10-26/build-release-audit.json) and [implementation inventory](evidence/acceptance-2026-10-26/implementation-inventory.json) retain the baseline evidence.

## Remaining gates

1. Both providers passed basic live OAuth, saved-account restart and private Fetch/Push; GitLab Clone also passed. Exercise real expiry, renewal, revoked grants and applicable organization/SSO restrictions without granting extra organization access merely for testing.
2. Fix repository opening with unresolved upstream configuration; implement and accept Pull merge/rebase policies and clear divergent-branch recovery.
3. Implement complete tab/workspace restoration; test multiwindow order, detach/rejoin, active selection and normal/crash recovery.
4. Add image comparison and accept the remaining review variants against explicit fixtures.
5. Implement PR/MR integration and test it with disposable hosted reviews.
6. Add CI/distribution/update/diagnostic workflows; accept Developer ID/notarization, clean-machine installation and upgrade trust. Run the compatibility, real IME/VoiceOver and sustained performance matrix.

No release-readiness claim follows from the passing local tests. The callback correction, regression test and acceptance evidence are included together in this change; the remaining gates above are still open.
