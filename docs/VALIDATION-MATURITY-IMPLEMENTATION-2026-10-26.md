# Maturity implementation validation — 2026-10-26

## Result and provenance

The working tree based on `18be8be8ebed25e4f587a6fe1963afcb80f1a8cc` implements the scope in [the tracker](IMPLEMENTATION-MATURITY-2026-10-26.md). Validation was captured before committing or pushing this feature batch; subsequent source delivery is recorded in Git history. No release upload/publication was performed. The existing GitHub repository remains the private distribution destination. Historical acceptance reports describe their original captures and are not rewritten by this report.

Staged app: **0.01 (20261026181848)**, minimum **macOS 26.0**, host **macOS 27.0.1 / arm64**. The bundle includes GitCore and pinned Sparkle 2.10.1. Mach-O `LC_BUILD_VERSION` reports `minos 26.0`; deep strict code-signature verification passed. This is a development build, not a notarized universal distribution package. Update actions remain disabled because the distribution public key is not provisioned in this build.

## Implemented behavior

| Area | Behavior and safeguards | Automated evidence |
| --- | --- | --- |
| Missing upstream | Initial/incremental snapshots open even when the configured upstream is absent. Banner exposes Fetch/tracking repair; badge and Pull explain unavailable counts. | Disposable repository with missing upstream; snapshot, incremental refresh and changed-upstream Pull refusal. |
| Pull | Fast-forward-only, Merge and Rebase review/default; captures HEAD/upstream; explicit no-autostash; conflicts use existing resolve/continue/abort UI; Sync All pushes only after successful reviewed Pull. | Divergent local bare origin/peer fixture for all policies; ff refusal, clean merge/rebase, untouched unrelated file, per-parent merge result comparison. |
| Sessions | Private atomic session metadata, saved tab IDs, repositories, native window groups/order/selection/frame, destination/search/options/commit/file/selection/bookmarks. Missing repos remain recoverable tabs. Corrupt/external state is preserved with a warning. | Reopen two repositories with draft/selection state, corrupt/external session refusal and suppressed native grouping/order restoration. |
| Review | Working/index/revision image comparison with side-by-side/opacity overlay, binary byte counts/hash/dimensions, rename-aware immutable reads; all-ref file history follows discovered earlier names. Merge result can be compared against each parent. | Exact staged/working/historical binary bytes, rename, absence and symlink refusal; unmerged side-branch history across a main-branch rename; existing comparison backend coverage. |
| Authentication | Public-client onboarding for Enterprise/self-managed servers, optional GitLab API scope upgrade; bounded transient retries only for device polling; secure connection/proxy advice without disabling certificates. | Provider HTTP/PKCE/refresh fixtures, exact-host credentials, OAuth helper regression and bounded retry tests. |
| PR/MR | Lists/detail/files/checks/statuses/comments, draft creation, comments/approval/request-changes (GitHub), merge/squash and close/reopen. Uses app-assigned credentials and server protections, reviewed SHA guards, changed-project confirmation refusal. | Mock GitHub/GitLab requests assert routes, credentials, draft and SHA fields, failed merge refusal; model/UI compiled and regression-tested. No new live hosted write was made. |
| SSH | Lists public fingerprints, creates new owner-only Ed25519 files with explicit unencrypted-key choice, refuses overwrite, adds selected unchanged keys to the system agent. Encrypted/hardware unlock remains a system action. | Real ssh-keygen against temporary directories, permissions/public parsing/collision guards. No user's keys or agent were modified. |
| LFS | Server lock listing, reviewed lock/unlock/explicit force unlock, HEAD/index/config and exact lock owner/ID stale guards. Remote changes clear prior lock UI. | Real Git LFS 3.8.1 against a loopback HTTP fixture, lock/unlock round trip, stale force-unlock refusal and unchanged worktree/index/HEAD. No external server writes. |
| Distribution/support | Private GitHub latest-release/asset-ID authentication, signed-feed/archive Sparkle integration, account picker, universal Developer ID/notarization packaging, manifest-bound draft-only upload, privacy-filtered JSON diagnostics, macOS 26 arm64/Intel CI configuration. | Asset/credential/URL/release guards, 4 Python metadata/appcast tests, shell/Python-block syntax checks, diagnostic exclusion test, app/framework signature checks and suppressed startup verification. Actual distribution still requires the gates below. |

Limits are intentional: image file reads are bounded to 16 MB per side, thumbnail dimension/pixel budgets apply, and only the first frame is rendered. All-ref history allows 256 distinct tips, 32 discovered names and 1024 bounded reads, with at most 10000 displayed entries. Hosted lists load at most 600 reviews and 1000 files/comments; binary/oversized server patches direct the user to the host. Check/pipeline lists are currently bounded to the server's first 100 results. Review creation targets branches in the selected project; fork target selection and inline review threads remain extensions. LFS lists show up to 1000 locks. API tokens and private keys are never embedded in source or release feeds.

## Commands and results

All Git writes used disposable local repositories. No test window was activated or made visible, and no live browser authorization was started in this batch.

- `xcodebuild build-for-testing -project GitPico.xcodeproj -scheme GitPico -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64'`: passed.
- Full `test-without-building`, serial Xcode runners, GitCoreTests + GitPicoTests: **388 total / 372 passed / 0 failed / 16 explicitly skipped**. Result: `.build/MaturityFinalRegression.xcresult`; log `.build/maturity-final-regression.log`. Subsequent focused runs cover later changes.
- Full application rerun with opt-in repository-open, branch-preview, 500-file render, tree-refresh benchmarks and feature captures: **150 total / 139 passed / 0 failed / 11 skipped**. Result: `.build/MaturityFocusedValidation.xcresult`. Its initial function filters omitted Swift Testing's trailing `()` and did not select the three Core tests; those tests were then explicitly selected and rerun below. No empty filtered run is counted as Core acceptance.
- Final three Core tests for private update assets, upstream guards and all Pull strategies/per-parent results, plus the corrected offscreen capture: **4 passed**. Result `.build/MaturityGuardsAndCapture.xcresult`; log `.build/maturity-guards-capture.log`.
- `python3 -m unittest discover -s script/tests -p 'test_*.py'`: **4 passed**. `bash -n` passed both release scripts; embedded Python blocks parsed successfully; `git diff --check` passed.
- `./script/build_and_run.sh --verify`: passed for background host and normal native startup paths, both `isActive=false` and `visibleWindows=0`. Native tab/menu/selection/routing checks passed. Output `.build/maturity-staged-verification.log`, sanitized evidence below.

The 16 full-suite skips were explicit opt-in credential, rendering, registration-probe and benchmark jobs. Five were enabled in the focused run. No skipped job is counted as having executed. A first screenshot rerun after app staging failed because the ordinary app build removed its hosted XCTest plug-in. The test host was rebuilt before repeating the final screenshot; this setup failure is not counted as a passing test. The retry passed one capture test in `.build/MaturityFinalCaptureRetry.xcresult`, with all windows still suppressed. Screenshot capture does not grant foreground interaction coverage.

## Performance samples

These are current bounded fixtures, not a before/after claim for this feature batch and not foreground FPS measurements. Raw reports live in [evidence](evidence/maturity-implementation-2026-10-26/).

| Fixture | Metric | Current result |
| --- | --- | --- |
| 10000 commits / 150 branches / 2000 untracked / 9 worktrees / 3 remotes | Open median, 3 samples | 248.9 ms |
| 600 commits / 120 branches / 2000 untracked | History preview median, 6 samples | 18.2 ms |
| 3000 commits / 120 branches / 500 changed files | Warm selection dispatch median | 0.13 ms |
| Same 500-file fixture | Warm history/detail task median | 60.3 ms |
| Same 500-file fixture | Largest observed main-actor heartbeat gap | 79.4 ms |
| 600 commits / 122 branches / 2000 ignored | Checkout / stash-save / stash-pop / merge medians | 215.5 / 185.2 / 247.9 / 342.1 ms |

The 500-file heartbeat gaps remain meaningful performance debt; the app must not promise instant completion or 60 fps for every repository. The preview fixture's store is isolated from persisted native workspace sessions, so these numbers do not establish autosave overhead or long-running memory/energy behavior. HEAD preservation and final operation state are asserted in the relevant fixtures.

## Visual evidence

Offscreen captures cover Pull, image comparison, review detail and Updates & Support in light/dark. Fixture review data contains no real account credential or network operation. The first content-only captures omitted material backgrounds/native control labels; the corrected capture includes the opaque hosting background and native frame. These captures support layout/contrast review; inactive window chrome and suppressed rendering do not establish mouse/keyboard/focus/VoiceOver behavior.

- [Pull](evidence/maturity-implementation-2026-10-26/pull-dark.png)
- [Image comparison](evidence/maturity-implementation-2026-10-26/binary-image-light.png)
- [Review detail](evidence/maturity-implementation-2026-10-26/review-detail-dark.png)
- [Updates](evidence/maturity-implementation-2026-10-26/updates-light.png)
- [Sanitized validation summary](evidence/maturity-implementation-2026-10-26/validation-summary.json)

## Outstanding external acceptance

- Live new PR/MR operations, expanded GitLab `api` registration/grant, organization SSO/rate-limit/revocation policy and enterprise server variants. Original GitLab `read_user`/`write_repository` authorization alone cannot authorize general MR API writes; use the explicit scope upgrade or an API-authorized token. Earlier basic OAuth/Git acceptance remains recorded separately.
- Actual provider LFS lock permissions/SSH hardware or encrypted-agent integrations; tests cover local fixtures and public tools only.
- Provision the dedicated Sparkle Keychain key/public verification key, intended Developer ID team and notary profile. Exercise two signed builds through private GitHub Releases, feed/asset redirects, signature rejection, download/install/relaunch, update recovery and account revocation. No signed production update was uploaded or installed. See [distribution setup](DISTRIBUTION.md).
- Run the configured CI on macOS 26 arm64/Intel. Current host testing is macOS 27.0.1 arm64; CI configuration and deployment metadata are not runtime acceptance. No CI run was triggered in this batch.
- Foreground keyboard/mouse/Chinese IME, full VoiceOver, multi-display window restoration and prolonged sleep/wake/offline/proxy/memory/energy tests remain unverified by instruction/environment. Large-repository rendering performance still has the measured gaps above.

These are acceptance gates, not claims that the implemented features are absent, and not evidence of complete Tower parity.
