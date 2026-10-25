# GitPico 0.6 validation

Date: 2026-10-24. Reference: installed Tower 18.0 (564). Host: macOS 27.0.1, Apple Silicon. Minimum target remains macOS 26.0; execution on that OS is still unverified.

## Outcome

- Full `swift test`: **75 tests passed**, 82.015 seconds, including the previous 54 tests and 21 new branch/tag/remote/stash tests. [Full log](evidence/swift-test-v6.log).
- A subsequent branch-deletion organization cleanup passed its targeted integration test, 8.947 seconds. [Focused log](evidence/branch-cleanup-test-v6.log). The later stash-selection fix changes UI store selection only; it was rebuilt and rechecked natively, without another full core run.
- Final SwiftPM build, ad-hoc signature verification and normal app launch passed. [Build/launch](evidence/build-and-launch-v6.log), [signature](evidence/signature-v6.log), [Mach-O deployment target](evidence/deployment-target-v6.log). Bundle 0.6.0 (6), minimum bundle/manifest/Mach-O target 26.0.
- This is a local development build. No source commit, push, notarization or release was performed. All source files remain untracked in the unborn project repository.

## Reference inspection

Tower was opened on the same disposable Client repository. Its branch context menu, New Tag form, Add Remote form, stash list and Apply Stash sheet were inspected. No Tower Git write action or preference change was performed.

- [Branch menu](evidence/management-tower-branch-menu-v6.txt), [Add Remote](evidence/management-tower-add-remote-v6.txt), [stash menu](evidence/management-tower-stash-menu-v6.txt), [Apply Stash](evidence/management-tower-apply-stash-v6.txt).
- Inspected screenshots: [Tower Stashes](evidence/management-tower-stashes-v6.png), [Tower Apply Stash](evidence/management-tower-apply-stash-v6.png).
- Official Mac guides: [Branches and Tags](https://www.git-tower.com/help/guides/branches-and-tags/overview/mac), [Stashes and Snapshots](https://www.git-tower.com/help/guides/working-copy/stash/mac).

GitPico follows the compact source list and stash list/detail structure, date/hash rows, expandable per-file diffs and the two Apply Stash choices: Delete After Applying and Restore Staging Area Status. It also has its own recovery and stash-rename flows. Tower's observed stash context menu exposed Apply/Delete; this inspection does not establish a matching Tower rename entry. Typography, toolbar arrangement, additional tabs and drag workflows still differ; no pixel-equivalence claim is made.

## Automated coverage

All tests use disposable local repositories; publication tests use local bare repositories and do not contact hosting services.

`ManagementTests.swift` (8 tests):

1. Branch revision/upstream selection, rename and stale-reference rejection.
2. Merged deletion, explicit unmerged override, expected-tip guard, recovery and clearing deleted branch organization.
3. Checked-out linked-worktree protection and common branch organization storage.
4. Lightweight/annotated tags, collision rejection, object-preserving rename and deletion recovery.
5. Remote multiple URLs, rename, custom configuration/refspec preservation, removal and configuration/upstream recovery.
6. Existing config lock and invalid input preserve configuration.
7. Publish branches/tags, upstream setup, reviewed server deletion and retained recovery objects.
8. An external remote advance after preview causes the explicit server lease to reject the push.

`StashManagementTests.swift` (8 tests):

1. Pop restores the exact index while retaining other entries.
2. Conflicting pop retains the saved entry and permits normal file resolution.
3. Keep Index and snapshot staging semantics.
4. Selected-file save, including literal bracket filenames, leaves other work intact.
5. Rename/delete/clear/recovery preserve saved content.
6. Repeated hashes have distinct row identities; stale ambiguous selectors are rejected.
7. Selected chunks and whole binary-file application preserve unselected changes.
8. Branch-from-stash starts at the saved base and restores staging.

`ManagementEdgeTests.swift` (5 tests):

1. Renaming the newest stash preserves its tree/parents and remains applicable.
2. Repeated identical snapshots preserve working/index content.
3. Selected-file application checks every patch before modifying any selected file.
4. Fetch prune/tags only changes the intended tracking/tag refs.
5. Multiple configured push URLs still publish to only the chosen endpoint.

### Defects found and corrected

- Git's `stash store` can report success without adding a reflog entry when the object already heads the stash. The initial duplicate-entry fixture made that incorrect assumption and then indexed an absent entry. The fixture now creates a real duplicate separated by another entry, asserts the count before indexing, and passes. Production rename now creates a new stash commit with the same tree/parents and preserved identities; only the message/committer date changes. This makes renaming the top entry work. The prior object is retained for recovery.
- Repeated identical snapshot saves may keep the same object and reflog length. Snapshot restoration handles that successful-save result instead of misclassifying it as no saved changes.
- A native walkthrough found duplicated Revision labels/menu indicators in the creation form. The final form shows one label and one disclosure indicator.
- The native stash rename/delete walkthrough exposed a selection race: the refreshed list could appear with no detail selected. Reload now falls back to the first available stash when the prior selected object disappears. A rename on the final rebuilt app kept the new top entry selected and its three-file details visible.

## Native application walkthrough

Created a fresh isolated environment with [create_management_demo.py](../script/create_management_demo.py):

`dist/ManagementReview-3k5yagqz/Client`, `Origin.git`, `Mirror.git`.

1. Inspected two initial stashes. The older one contains a staged Layout.swift edit, an unstaged README.md edit and untracked Draft.txt. Selected it, expanded its files, then applied with **Restore Staging Area Status** and **Delete Stash After Applying Changes** enabled. Only that entry was removed. The index contained spacing 14; README remained unstaged and Draft.txt returned. [Exact result](evidence/management-native-pop-v6.json), [review sheet](evidence/management-pico-apply-stash-v6.png).
2. Created **Native snapshot verification** through the Working Copy menu. The staged, unstaged and untracked state remained unchanged while a stash was added. [Exact result](evidence/management-native-snapshot-v6.json). Saved **Native recovered work** afterward, leaving the Client clean.
3. Created **native-review** without checkout, then renamed it **native-renamed**. HEAD remained main. Added **mirror** pointing at Mirror.git, published the branch through the reviewed destination sheet and selected upstream setup. The bare ref and tracking/upstream values matched. [Review](evidence/management-pico-publish-v6.png), [result](evidence/management-native-publish-v6.json).
4. Renamed mirror to **review-mirror** and explicitly set its Push URL. The repository Remotes tab displays Fetch URLs, Push URLs and Fetch mappings. Removed the remote, recovered it through Recover Deleted Items > Remotes, then fetched it. Its URL, push URL, mapping and available upstream settings returned. [Remotes view](evidence/management-pico-remotes-v6.png).
5. Created annotated **v0.6-native** at HEAD with message **Native management review**. `cat-file -p` confirms a tag object with that message and target. [Final form](evidence/management-pico-create-tag-v6.png).
6. Pinned native-renamed, archived it and observed Archived Branches and Unarchive Branch. Deleted the merged branch with the unmerged override disabled. Recovered its object as **native-restored**; main/HEAD and working files remained unchanged. Deletion removed the former pin/archive metadata.
7. Renamed the newest stash, deleted it, then restored it through Recover Deleted Items > Stashes. Its three files and saved index were retained. After the final rebuild, renamed it **Native management review** and verified the selection fix. Expanded all three files in split view. [Final screenshot](evidence/management-pico-final-stashes-v6.png), [AX tree](evidence/management-pico-final-stashes-v6-ax.txt).

Every screenshot linked in this walkthrough and both Tower screenshots above was visually inspected. The older branch creation screenshot retains the subsequently fixed duplicate-label state and is not final visual acceptance.

Final demo: **main**, HEAD `9e34fbc3fda66480ff422bc766d3147c73360e0c`, clean; three stashes, v0.6-native and native-restored retained. Mirror.git still holds the published native-renamed server branch, as expected after deleting only the local branch. Recovered local branch configuration is not implicitly restored. [Final exact Git state](evidence/management-native-final-v6.json). The app remains open on the final expanded Stash details.

## Data and concurrency boundaries

- Branch/tag deletes check the expected object and keep recovery refs. Tag rename uses an update-ref transaction. Branch rename and remote rename/remove use native Git operations; this is not a cross-config/ref application transaction. A failed compound action can leave a created branch or a completed server push; the app reloads the actual result rather than claiming rollback.
- Remote URL changes use a lock, stale-content check and atomic local config replacement, preserving unrelated keys. Custom mappings are displayed and preserved, not edited. Configurations inherited from other scopes/includes do not have dedicated UI acceptance in this pass.
- Force pushes and remote deletions use the exact server object seen in preview. Changes on the server invalidate that lease. A single explicitly selected push URL is used; upstream setup is conservatively restricted to the matching fetch endpoint.
- Management metadata is in the common Git directory's `gitpico/management/`; recovery refs are under `refs/gitpico/recovery/` and are not automatically pruned. Restoring a branch/tag creates an absent ref and does not overwrite an existing one. Branch recovery does not restore deleted branch upstream configuration. Remote recovery separately restores saved config and still requires Fetch.
- Stash object lookup guards ordinary ordinal shifts and rejects ambiguous stale duplicate entries. Native stash drop/clear still have a narrow external-process concurrency window; the journal has no cross-process lock. Snapshot save/reapply is not an atomic filesystem transaction. Failed application retains the stash but may leave partially applied working changes.
- Stash conflicts are unmerged files rather than an active merge operation. Use the existing resolver and stage/commit restored work; there is no native merge Continue/Abort for a stash conflict.

## Remaining acceptance and scope

Individual-line stash application, drag-and-drop, automatic stash around checkout/pull/rebase, background fetch, custom refspec editing and Pull merge/rebase strategies are not implemented. Stash details currently offer expandable file diffs, without Tower's separate tree tab. Structural/binary stash changes apply as complete files.

Existing-key tag signing has a code/UI path, but real GPG/SSH signing and signature verification were not exercised. Real hosted authentication, network failures and provider-account flows remain unverified; all pushes here were local. The history Undo journal still excludes these management operations; deleted-item recovery is a separate flow.

Full VoiceOver/keyboard journeys, light appearance, large repository performance and macOS 26 runtime checks remain outstanding. The [98-unit parity matrix](TOWER-PARITY-2026-10-24.md) now records 26 covered, 23 partial, 46 missing and 3 unverified bounded units; these counts are not a completion percentage.
