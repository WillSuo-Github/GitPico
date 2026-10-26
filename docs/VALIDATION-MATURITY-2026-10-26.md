# Refresh, conflict drafts, authentication and activity — 2026-10-26

Build: **0.01 (20261026130241)**. Deployment target remains **macOS 26.0**. Executed on **macOS 27.0.1 / arm64**. All Git writes used disposable local repositories; no user repository or hosted server was used for acceptance writes. This is an uncommitted working-tree implementation on the existing branch; source hashes identify the checked code.

## Delivered behavior

- **Automatic refresh** watches the working directory, actual Git directory and common Git storage through FSEvents. Paths are resolved before watching, including linked Worktrees. Events coalesce for 300 ms, reads defer during writes, and activation requests revalidation. Drafts, selections and warm history survive file-only refreshes. HEAD/ref changes invalidate history; operation/HEAD changes refresh Undo, rebase progress and automatic-stash recovery. Selected diffs reload even when a file remains Modified.
- **Background Fetch** is disabled by default, enabled in Settings → General → Workflow. Open repositories are checked every 30 seconds; eligible idle Fetch runs at most once per five minutes per repository, with one background reservation across tabs. It does not Pull/Push or alter the index, working files or HEAD. History navigation and commit text entry remain available while Git writes are guarded. Interactive helpers are disabled for this path; connected HTTPS profiles and existing system SSH configuration are supported. Failures remain in activity history without opening an alert.
- **Conflict drafts** autosave after 300 ms to per-root archives beside the repository library, outside Git storage. Each archive retains its source/index/operation snapshot. A changed external file/index cannot be silently overwritten. Drafts survive restart and externally resolved/deleted conflicts; Repository → Saved Conflict Drafts supports selectable text, Copy, Export and confirmed Discard. Normal close/quit flushes synchronously and retains the tab on edited-draft save failure. Files use mode 0600 and app-owned archive directories 0700. Limits: 128 drafts, 1 MiB edited text per draft, 64 MiB archive. A crash inside the debounce interval can lose the latest keystrokes. Unreadable/external archives are preserved; new edits require export if saving remains blocked.
- **Performance** retains unchanged history and skips log/count reads during ordinary working-file refresh. Immutable commit message/file/metadata/statistic reads run concurrently. Existing native row reuse, lazy detail rendering and cache invalidation rules remain intact.
- **Authentication** adds GitHub/GitLab/Other HTTPS PAT profiles in Keychain, per-repository assignments, a clone profile picker, identity verification, token rotation and a read-only remote test. Metadata contains no token. The helper runs before app startup, answers Git's `get` only for the exact HTTPS host/username, and is supplied through per-command config; it does not persist secrets to Git config. System SSH and normal system Git helpers remain available. Provider verification uses HTTPS, bounded responses and rejects credential-bearing redirects. Encrypted SSH keys still require the system agent. Inspect System Authentication reports configuration; a set SSH_AUTH_SOCK is not presented as proof of a working agent.
- **Network Activity** is shared across tabs and survives repository changes. Access: Repository → Network Activity, ⌘⌥N, or status bar. It records transport phase, live output, progress where Git supplies it, elapsed running time, terminal result, advice and explicit cancellation. Fetch/clone/push/pull request progress even with captured stderr. Local LFS status/config inspection and submodule status are excluded. LFS transfers and submodule add/update are recognized. Up to 100 entries, bounded output and an under-8-MiB journal are saved locally; URI/authorization/password/token patterns and the active saved secret are redacted. Fetch retry is available only from its original repository. Push/Pull are never automatically retried. Cancellation terminates the local Git process; it cannot roll back a remote write or guarantee already-started child/server work stopped. Review refreshed state before retrying.

## Regression and failure evidence

The [test run record](evidence/maturity-2026-10-26/test-runs.json) retains reported totals, opt-in skips and the failing Worktree check before its correction. [Selected output](evidence/maturity-2026-10-26/checks.txt) preserves the relevant result lines.

- Complete GitCore run: **216 tests reported passed**, 205.593 seconds. Subsequent changes resolved observation paths and excluded local LFS/submodule inspection from activity; the latter adds one new Core test.
- Final targeted network/Core run after those changes: **5 tests passed**, 0.341 seconds: real local read events, delayed fake-SSH cancellation/redaction, helper host/protocol/action restrictions, log redaction, and local-inspection exclusion. Together with the full Core run this covers 217 unique Core tests, rather than 221 independent tests.
- Final complete App run: **136 tests reported passed**, 61.615 seconds. The runner also reports 12 opt-in tests skipped; these totals must not be interpreted as 136 foreground interaction paths. The new panel capture was explicitly enabled. Real FSEvents coverage includes repeated external content edits, refs, busy deferral, warm history retention and linked Worktrees/shared Git refs. Draft coverage includes restart, stale source/index rejection, external archive changes, revision ordering, permissions and corrupt-file preservation.
- Background Fetch against a disposable local bare repository preserved HEAD, byte-identical index and dirty working-file content, allowed history navigation/typing, and guarded commits.
- Actual Keychain helper acceptance ran separately in the complete App run in `maturity-final-app-tests.log`: one temporary UUID-owned fake credential was added, updated, read by the app's actual Git helper through `git credential fill`, removed and confirmed unreadable. No user's token was read or changed. Provider API URL/header/parsing behavior uses fixtures; hosted account acceptance was not performed.
- One initial linked-Worktree check failed because Git returned common storage containing `..`; canonicalization fixed it, and the final complete App run passed. Earlier archive-path checks also rejected the system `/var` alias; the owned archive directory remains checked without rejecting that legitimate system ancestor. These were implementation issues, not waived tests.
- `git diff --check` passed. `./script/build_and_run.sh --verify` built/staged the app and verified code signing, suppressed startup and native menu/tab routing. [Background report](evidence/maturity-2026-10-26/background-verification.json), [native startup report](evidence/maturity-2026-10-26/native-startup-verification.json), [bundle metadata](evidence/maturity-2026-10-26/build-metadata.json) record zero visible windows and no activation.

## Performance experiment

The opt-in native history experiment used **3,000 commits, 120 branches and 500 changed files**. Three initial branches and six repeated previews were measured in a suppressed window. [Raw samples](evidence/maturity-2026-10-26/branch-preview-500-files.json), [comparison](evidence/maturity-2026-10-26/performance-summary.json).

| Measurement | Previous branch batch | Current batch |
| --- | ---: | ---: |
| Initial detail task median | 152.84 ms | 138.60 ms |
| Repeated history/detail task median | 48.42 ms | 43.40 ms |
| Repeated selection-call median | 0.126 ms | 0.115 ms |
| Repeated maximum-main-actor-gap median | 36.13 ms | 30.49 ms |
| Largest main-actor scheduling gap in the run | 49.75 ms | 69.89 ms |

Machine load was not controlled between runs. The worse single scheduling spike prevents claiming universal smoothness or a fixed improvement percentage. These are task/scheduling timings, not visible foreground FPS. Separate command tracing verifies that file-only refresh does not run history log/count commands.

## Suppressed visual checks

Authentication, activity and recovered-draft panels were captured in both appearances and inspected for readability, spacing, selection and reachable buttons. The authentication form scrolls to diagnostics/help below the initial viewport. Native list widths were capped to leave room for detail text. Log/code text intentionally supports horizontal scrolling.

- Authentication: [light](evidence/maturity-2026-10-26/authentication-light.png), [dark](evidence/maturity-2026-10-26/authentication-dark.png).
- Network activity: [light](evidence/maturity-2026-10-26/network-light.png), [dark](evidence/maturity-2026-10-26/network-dark.png).
- Conflict drafts: [light](evidence/maturity-2026-10-26/conflict-drafts-light.png), [dark](evidence/maturity-2026-10-26/conflict-drafts-dark.png).

Captures used hidden, nonpresenting native windows and metadata-only account fixtures. They do not establish foreground mouse/keyboard/IME behavior, sheet transition focus, VoiceOver or complete Settings scroll interaction.

## Remaining acceptance / scope

OAuth browser login, in-app SSH-key creation/unlocking, real GitHub/GitLab API/Git access and hosted LFS authentication were not implemented or validated by this batch. Existing SSH setup can be used, but encrypted-key prompting and unknown-host onboarding require system configuration. Provider read verification does not prove write permissions. Foreground acceptance, long-running large-repository/energy behavior and macOS 26 runtime acceptance remain open. The minimum target is not evidence of a macOS 26 run.

## Reproduction

Use `xcodebuild test -project GitPico.xcodeproj -scheme GitPico -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO` for the complete scheme. Opt-in app flags must be prefixed with `TEST_RUNNER_` when launching through Xcode:

- `GITPICO_CAPTURE_MATURITY_PANELS=1`, `GITPICO_MATURITY_CAPTURE_OUTPUT=<absolute output folder>`.
- `GITPICO_VERIFY_KEYCHAIN_HELPER=1` for the disposable app-owned Keychain item.
- `GITPICO_RUN_PREVIEW_RENDER_BENCHMARK=1`, `GITPICO_PREVIEW_RENDER_CHANGED_FILES=500`, `GITPICO_PREVIEW_RENDER_BENCHMARK_REPORT=<absolute JSON file>`.

Individual Swift Testing identifiers include parentheses, for example `'-only-testing:GitCoreTests/localLFSAndSubmoduleInspectionDoesNotCreateNetworkActivity()'`. A successful build with a filter that selected zero tests is not test evidence.

[Source hashes](evidence/maturity-2026-10-26/source-sha256.txt) identify all checked Swift source/test files. Local verbose build/test logs remain in `.build/maturity-*.log`; the evidence above avoids persisting unrelated operating-system noise.
