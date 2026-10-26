# GitPico milestones

## Implemented in 0.1

Open existing repositories; inspect status/diffs; stage/unstage/commit; browse ancestry and ref history; create/check out branches; basic sync; stash inspection/application. SwiftUI on macOS 26+.

## Implemented in 0.2

- Captured the installed Tower 18's Working Copy, History, viewing options, Branches Review and General settings using the same PicoDemo repository.
- Matched source-list/content-list proportions, compact file rows and collapsible branch folders. Added persistent widths and back/forward navigation.
- Added chunk staging, context/whitespace controls, Amend, Sign Off and draft restoration.
- Added history paging, full-message search, sorting/filtering/display options, complete commit metadata/statistics, expandable per-file diffs and historic file trees.
- Added branch comparisons, merge/rebase/cherry-pick, clean-worktree guards and conflict continue/abort.
- Added clone/init and repository General/Ignores/Excludes settings with stale-write checks.

## Implemented in 0.3

- Line staging/unstaging in unified and split views, including Shift-click ranges, stale-diff guards, new/deleted files, CRLF and missing final newlines.
- Persistent unified/side-by-side mode for working files, commit Changesets and stash previews; shared vertical and independent horizontal scrolling.
- In-app conflict source/base previews, per-block choices, manual result editing, navigation-preserved drafts and save/stage/continue workflow. Merge/rebase/cherry-pick recovery is tested. Whole-version binary and modify/delete resolution are supported for regular files.
- Tower-aligned operation card above the file list, conflict-only filtering, compact layout controls and darker editor surfaces.

## Implemented in 0.4

- Interactive rebase plan editing for linear ranges: reorder, Pick/Reword/Edit/Squash/Fixup/Drop, optional new base, edit-stop amendment, conflict continuation, Skip and Abort.
- Persistent per-worktree Undo/Redo for commits, Amend, integrations and Restore HEAD, including initial-commit undo and external-HEAD guards. Recovery refs retain original and rewritten history.
- Reflog event browsing, event dates, filtering/paging, old-commit previews, branch recovery and file-preserving/clean-tree restore modes.
- Matched Tower's Reflog list width, hash/action/date row structure, event badges and sidebar placement. Added review sheets for undo/redo/recovery.

## Implemented in 0.5

- Read-only Tower bundle metadata, selected symbols/resource filenames, native menus/settings and official macOS guides were cross-checked. The [98-unit parity matrix](TOWER-PARITY-2026-10-24.md) records covered, partial, missing and unverified scope; no overall parity completion is claimed.
- Added rename-following file history with per-revision Diff/Raw/Blame, loaded-history search, pagination, a tracked-file picker, right-side line attribution and original-commit inspection.
- Added arbitrary branch/tag/commit comparison, optional merge base, immutable snapshot diffs, rename-aware statistics, context/whitespace settings and unified/split rendering.
- Added single-commit Revert, explicit merge-mainline selection, stale-HEAD and clean-worktree guards, conflict Continue/Abort and persistent Undo/Redo.
- Fixed historical raw-file inspection: a deleted name containing brackets could be silently returned as empty by Git show; strict cat-file blob reads now reject absent blobs.

## Implemented in 0.6

- Branch revision/upstream selection, tracking checkout, rename/delete/recovery, pin and archive shared across worktrees; checked-out-worktree and expected-tip guards.
- Lightweight/annotated tag lifecycle and publication; existing-key signing controls remain unverified against real keys. Renames retain annotated objects and embedded original names.
- Fetch/push URL arrays, remote rename/remove/recovery, upstream preservation, selected/all fetch with prune/tags, exact-destination push previews and explicit force/delete leases. Tested against local bare servers.
- Stash selected-file/untracked/keep-index saves, full apply with optional index and pop, snapshots, file/chunk application, rename/delete/clear/recovery and branch-from-stash. Conflicts retain saved content. Native Tower Apply Stash options and compact list/detail layout were cross-checked.
- Full 75-test pass; final branch-organization cleanup targeted pass; native write walkthroughs and final rebuilt application. See [0.6 validation](VALIDATION-0.6.md).

## Interaction batch — 0.01 date builds

- Marketing version fixed at 0.01; monotonically increasing Shanghai date/time Build Number. Settings reads actual bundle metadata.
- Automatic stash offer/reapply with saved index, untracked files, operation-pause persistence, interrupted-save recovery and explicit restoration review.
- Selected-line stash application in both layouts, reviewed drag routes for working files/stash parts, refs and commits, and headless routing coverage.
- Native file-to-stash and selected-lines-to-worktree drops passed. Whole-list drop was still under review when the user requested background-only testing. Further foreground acceptance stopped; final bridge changes were built and routing-tested without windows.
- Background verification now bypasses SwiftUI scenes/restoration, prohibits activation and asserts zero visible windows. See [interaction validation](VALIDATION-INTERACTIONS-2026-10-24.md).

## Background drag follow-up — 0.01 date builds

- Windowless AppKit destination callbacks now cover whole stashes, copy/move negotiation, multi-item file aggregation, cancellation and busy/payload changes.
- Captured destination branch/HEAD prevents a reviewed drop or an asynchronously prepared rebase plan from targeting an externally switched branch. Rebase drags are scoped to a plan UUID; row placement is consistent in both directions.
- Full regression: 89 GitCore and 11 interaction tests passed. No foreground inspection was performed. Real OS gesture/List/layout acceptance remains incomplete. See [drag follow-up validation](VALIDATION-DRAG-2026-10-24.md).

## Local changes batch — 0.01 date builds

- Selected/all file discard with separate unstaged and staged+unstaged scopes; unstaged chunk/line discard in either layout.
- Per-worktree file/index recovery snapshots saved before mutation, private storage, expected-file/index/HEAD guards and GC-pinned index blobs. Reopen and interrupted multi-file recovery are covered.
- Patch preview/import with working/index/both and reverse options, atomic preflight, binary/rename support, staged/unstaged/selected-line export and individual non-merge commit mailbox export. Native panels preserve exact bytes and refuse replacing existing files.
- Background-only validation; conversion/link/size restrictions and remaining UI acceptance are explicit. See [local changes validation](VALIDATION-LOCAL-CHANGES-2026-10-24.md).

## Historical file batch — 0.01 date builds

- Guarded restore from immutable historical objects, optional index update, renamed destinations and explicit pre-deletion source, with persistent local recovery.
- Original file/new-folder and ZIP exports for selected files/folders and complete commit/ref trees. Raw blob bytes, executable modes, bounded batch reads and atomic no-overwrite output are covered.
- Safe relative symbolic links are preserved in exports; submodules are declared empty directories. Restoration still supports regular files only.
- Background-only focused integration, independent ZIP validation and Store routing tests. See [historical files validation](VALIDATION-HISTORICAL-FILES-2026-10-24.md).

## Repository navigation batch — 0.01 date builds

- Persistent repository library: registration, favorites, custom display names, nested groups, scope/search, move/sort/reorder, non-destructive removal and Git-validated relocation.
- One-time legacy recent migration, durable twelve-entry recents alongside older registrations, and external-edit/cooperating-lock/corrupt-storage protection.
- Cmd-Shift-O Quick Open with name/path/group search, favorites/recency ranking and keyboard selection; Clone moved to Cmd-Option-O. Existing-window opening preserves normal Git guards.
- Headless persistence, real temporary-repository routing and drag-session coverage; real native UI/keyboard/IME/drag acceptance remains pending. See [repository library validation](VALIDATION-REPOSITORY-LIBRARY-2026-10-24.md).

## Working browser and tools batch — 0.01 date builds

- Changed/all/ignored/assume-unchanged working-file filters, unmodified/raw previews, explicit reviewed Force Add and existing index recovery.
- Cmd-Shift-A Quick Actions with file/ref/remote/stash/commit lookup, normal reviewed actions and stale-session protection.
- Configurable diff/merge helpers with literal argv, FileMerge preset, persistent private copies, diagnostics and explicit result review/apply. Core comparisons cover binary, roots and renames; merge application guards source and reviewed result changes.
- Full and focused background integration checks; no external GUI or foreground UI activation. See [browsing/tools validation](VALIDATION-BROWSE-TOOLS-2026-10-24.md).

## Worktree and submodule batch — 0.01 date builds

- Worktree list/open, new/existing/detached creation with immutable previews, occupied-branch protection, lock/unlock, clean move, verified external-relocation repair and non-force removal. Branches, commit references and metadata backups survive removal.
- Related-repository sidebar/list/detail views, per-branch Worktree creation, native review sheets, same-window opening and Quick Actions open/init/create routes.
- Submodule add/init and recursive clone, gitlink/HEAD/dirty status, Fetch, recorded-version update, detached checkout, URL/path/sync, Git-dir absorption/missing-pointer repair, deinitialize and removal retaining Git data. Per-linked-worktree module storage is handled separately.
- Disposable repositories cover stale previews, unsafe destinations/transports, local/ignored/nested changes, recursive clone and Git pointer repair. All acceptance remains in the background; native layout/keyboard/mouse and macOS 26 runtime acceptance remain pending. See [worktree/submodule validation](VALIDATION-WORKTREES-SUBMODULES-2026-10-24.md).

## Nested migration, batches and management recovery — 0.01 date builds

- Move initialized nested/embedded submodule repositories, and move/remove/restore linked Worktrees containing initialized nested modules. Reconnect Git-file and core.worktree pointers without network reconstruction.
- Native multiselection, reviewed Worktree and submodule operation batches, persisted per-item results, stop-after-current and review-before-resume. Completed batch history stays inspectable.
- Private before/after management records, full directory snapshots and GC-pinned objects; guarded staging/config/directory restoration, quarantined current folders and resumable restore after metadata locks. Earlier index-only records recover into new detached trees; unknown native interruptions or newer edits can extract saved files into a new non-repository folder.
- Background fixture coverage includes nested/embedded/per-linked-worktree storage, unborn parents, stale previews, parent-HEAD independence for Worktree recovery, branch reuse, tampering/path traversal, cancellation and cooperating process leases. See [advanced validation](VALIDATION-RELATED-ADVANCED-2026-10-24.md).

## Repository infrastructure — 0.01 date builds

- Main working-directory/shared-storage migration, linked/nested pointer reconnection, external full-copy journals, resumable guarded restoration and independent saved-main recovery. Repository-library prefix relocation preserves saved metadata.
- Offline reviewed multi-repository pointer repair after external moves, editable actual locations, staged module path mappings and repair/metadata-restore history. Foreign live storage and changed metadata remain protected.
- Backed-up force deinitialize/remove, explicit locked-Worktree cleanup and selected missing-registration prune; complete saved submodule Git data recovers into a new independent repository with conflict/index state.
- Explicit empty-directory Worktree reuse and five submodule addition modes, including existing/retained repositories and fresh cloning after retained-storage backup. Live nested linked users block storage removal.
- Background-only disposable-repository and application-routing validation; native Tower pixel/focus/mouse parity and macOS 26 runtime acceptance remain pending. See [infrastructure validation](VALIDATION-REPOSITORY-INFRASTRUCTURE-2026-10-24.md).

## Git LFS and classic Git Flow — 0.01 date builds

- Installed Git LFS detection and GUI PATH resolution, local filters/protected hooks, source-aware pattern/literal tracking, current object/status/cache overview and recoverable index conversion for previously normal Git files.
- Real object Fetch/Pull/Push/Checkout with immutable revisions, explicit reachable-history transfer, native progress and diagnostics, and full-object vs pointer-only cloning. Tests use disposable local bare/object storage; hosted LFS authentication/locking and history migrate/prune are unverified or absent.
- Native classic Git Flow configuration, feature/release/hotfix/support start, remote tracking, reviewed completion with annotated/signed-tag options, production/development integration and deferred topic deletion.
- Persisted step history, merge-source ownership, restart/conflict/manual-merge continuation, protected Stop and signing-failure retention. External git-flow scripts/hooks and custom/stacked workflow engines are separate scope. See [LFS / Flow validation](VALIDATION-LFS-FLOW-2026-10-24.md).

## Remaining

- Enterprise/self-managed OAuth onboarding, in-app SSH-key onboarding and Pull Requests; user-authorized hosted-provider acceptance remains pending.
- Image/binary diff rendering, external tool GUI/directory-diff acceptance, symlink/submodule conflict handling.
- Rebase merge/root ranges, a broader undo model for non-history actions, all-ref file lineage, merge-commit patch export and richer Blame navigation.
- Remaining drag variants and native acceptance, real tag signing and remote authentication acceptance; expanded patch conversion/link support, external-main-Git storage migration and arbitrary corrupted-pointer reconstruction, hosted LFS authentication/locking, LFS history migration/pruning, external Git Flow CLI extensions/hooks, custom workflows, stacked branches and Graphite.
- Expanded Quick Actions (hierarchical Tab options), tabs/multiple windows, automatic branch cleanup, commit templates and user profiles.
- Further matching of toolbar groups, typography, selection appearance, density and tied-date graph ordering against Tower.
- macOS 26 runtime execution, broader large-repository/foreground profiling and VoiceOver audits; bounded history benchmarks and suppressed light/dark captures are available.
- Icon, localization and distribution signing/notarization.

Do not represent unimplemented controls as working. Verify write operations in disposable repositories before exercising them on personal projects.

## Branch preview experience — 0.01 date builds

- Replaced navigation-wide repository refreshes with cancellable bounded history reads and an in-memory LRU keyed by resolved tip and history options. Warm pages display synchronously, then revalidate the tip. Refresh, Git writes and repository sessions invalidate pages.
- Cached graph/month groups, detached presentation preparation, derived sidebar outlines, cached immutable commit details and stale-request guards keep branch selection independent from working-copy/submodule scans.
- Reorganized the compact native toolbar into navigation, quick actions, Undo/Redo, network, branch/integration, stash, refresh and native search. Git Flow remains in the integration menu; Synchronize remains in Repository commands. Saved Tower reference captures informed grouping; no new foreground visual acceptance was performed.
- [Validation and before/after measurements](VALIDATION-PREVIEW-PERFORMANCE-2026-10-24.md). Broader Tower parity and actual large-repository rendering acceptance remain incomplete.

## Navigation and menu polish — 0.01 date builds

- Repository/Branch/Commit command groups separate synchronization, integration, selection-based actions, export and management; contextual availability is shared with toolbar controls.
- Branch menu and history Preview/Check Out affordances distinguish viewing from switching; captured-target checkout rejects changed references, active operations and other Worktree occupancy while retaining Git's local-edit protection.
- Per-destination query/options/commit bookmarks restore on Back/Forward and sidebar revisits. Cached revalidation preserves intervening selection; rewritten histories fall back to the tip and reveal it. This restores a selected row, not an exact pixel scroll offset.
- Native List rows replace nested buttons, selected/inactive text colors follow AppKit, reference overflow uses a count, and context actions are grouped. Native search has Cmd-F routing and Back/Forward have keyboard commands.
- Light/dark row components were rendered without windows; complete toolbar/keyboard/mouse/focus acceptance remains pending. See [experience validation](VALIDATION-EXPERIENCE-2026-10-24.md).

## Working copy interaction polish — 2026-10-25 date builds

- File-list filtering and sorting are prepared in the background; the model retains an active file within multi-selection and prunes filtered/missing selections. Clearing selection cancels its diff.
- Stage/Unstage selection routes act on the selected changed files, with context-row fallback and explicit exclusion of ignored/unmodified/conflicted entries. A partial-stage checkbox stages the remaining changes; Unstage remains explicit. Stage All continues to include changed files hidden by the filter, with a tooltip explaining its scope.
- Working diff requests are deduplicated and guarded against late results; read errors have Retry. Prepared hunks, visible selectable lines and split alignment are retained while selecting lines or changing layout. Truncated/structural diffs keep existing partial-write restrictions.
- Commit readiness and success text explain state; Cmd-Return lives in a Working Copy-scoped command. Rejected nonmutating-hook commits retain the complete draft/index; successful partial commits preserve the remaining working content and current file. Git commit success is separated from a later local Undo journal/refresh failure, with an explicit success receipt and recovery warning.
- [Background validation and windowless light/dark components](VALIDATION-WORKING-EXPERIENCE-2026-10-25.md). Index-only write refreshes still await full repository metadata; splitting those refreshes remains a performance follow-up. Full mouse/keyboard/IME, native list selection and large-diff drawing acceptance remain pending.

## Incremental write refresh — 2026-10-25 date builds

- Index-only file/chunk/line and reviewed Force Add operations use working-state refreshes and keep warm history when HEAD stays unchanged, on both successful and failed writes. Commit/Amend refresh HEAD/refs, bounded history, divergence and Undo without a full snapshot/count or unrelated metadata loading.
- Working files/side/selection stay coordinated; all-files index flags and ignored/policy-dependent browsing are refreshed within the file-data domain. HEAD movement during reads is checked before publishing, with bounded retries.
- Worktree/submodule, stash, workflow, remotes and organization are refreshed when opened/requested. Repository session and metadata epoch guards reject old data; independent failures do not block unrelated scopes, and required-action failures are reported.
- A single Git administrative-directory lookup replaces repeated operation-marker subprocesses, including linked Worktrees.
- The previous pending write-refresh split is now implemented for staging/unstaging/commit. Other Git administration still uses full reload; external unrelated reference/config changes require explicit Refresh or the appropriate management page.
- [Benchmark, regression and background packaging evidence](VALIDATION-INCREMENTAL-REFRESH-2026-10-25.md).

## Checkout, Stash and integration refresh — 2026-10-25

- Checkout/create-and-checkout, all Stash sheet executors, automatic Stash recovery, integrations, conflict resolution and continue/abort use working-tree incremental refresh.
- Refresh once after success or rejection; keep the original Git error if refreshing also fails. Publish live stash entries and automatic recovery banners before releasing busy; defer unrelated management inspection.
- Reload bounded history/refs/upstream only on an actual HEAD change; retain stable pages after stash-only writes and no-op/rejected operations. Stale Worktree indicators no longer override backend occupancy validation.
- Conflict redirection cancels the old history request, clears incompatible search and selects the actual conflicted file.
- Background validation and timings: [working-tree refresh report](VALIDATION-WORKING-TREE-REFRESH-2026-10-25.md).

## Refresh, drafts, authentication and network activity — 2026-10-26

- FSEvents watches working and actual/common Git storage; coalesced reads defer across writes, revalidate after foregrounding and retain unchanged history. Git metadata/HEAD moves refresh recovery state. Pure working-file events skip history log/count subprocesses.
- Conflict edits persist in private archives, with source/index stale guards, recovered-draft review, Copy/Export and explicit Discard. Closing and quitting synchronously flush edited drafts; corrupt or externally modified archives are not overwritten.
- GitHub/GitLab/other HTTPS PAT profiles live in Keychain, with per-repository assignment, identity verification, exact-host Git credential helper, token rotation and remote read tests. System SSH remains supported; OAuth and SSH-key creation/unlocking are outside this batch.
- Shared network activity records running/completed Git transports, phase progress/output, failures and explicit cancellation, with redacted bounded local history. Retrying Fetch is scoped to its original repository; Push/Pull are not automatically retried. Opt-in five-minute background Fetch avoids prompts and preserves worktree/index/HEAD.
- Immutable commit-detail reads run concurrently. Background branch-render measurements, disposable Git integration, temporary Keychain helper acceptance and suppressed light/dark panel captures are recorded in [validation](VALIDATION-MATURITY-2026-10-26.md). Foreground mouse/keyboard/VoiceOver, real hosted authentication and macOS 26 runtime remain unverified.

## GitHub and GitLab OAuth — 2026-10-26

- Registered GitPico OAuth apps under the user's GitHub and GitLab accounts. Public Client IDs are bundled; no Client Secret is required or embedded. GitHub Device Flow is enabled; GitLab is a non-confidential public client with read_user/write_repository scopes and an exact gitpico callback.
- Native Authentication offers GitHub device authorization and GitLab browser PKCE, one-time state/code validation, explicit cancellation/timeouts, identity verification before Keychain saving and reconnect without changing repository bindings. Existing PAT profiles decode unchanged; Clone and repository pickers identify OAuth profiles.
- Keychain retains access/refresh tokens, expiration and issuer/client configuration. The exact-host Git helper renews expired OAuth credentials on demand, with cross-process locking and token-rotation preservation. SSH and unrelated HTTPS hosts do not require the selected OAuth profile to be renewed. Provider revocation remains explicit in the user's authorized-app settings.
- [Registration, background regression, Keychain/helper coverage and remaining user acceptance](VALIDATION-OAUTH-2026-10-26.md). No foreground GitPico testing or automatic acceptance of provider repository grants was performed.
