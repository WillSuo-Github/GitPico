# GitPico interaction validation — 2026-10-24

Follow-up: [background drag validation](VALIDATION-DRAG-2026-10-24.md) adds actual windowless destination-callback coverage and a 100-test complete run. The observations below remain the earlier pass.

Current marketing version: **0.01**, fixed until release. Each staged app build gets a new Asia/Shanghai `yyyyMMddHHmmss` Build Number. Same-second builds and a clock earlier than the preceding build advance the previous timestamp by one second. Historical 0.1–0.6 validation names describe earlier captures, not the current version policy.

Host: macOS 27.0.1, Apple Silicon. Minimum bundle, manifest and Mach-O target: macOS 26.0. No macOS 26 runtime acceptance is claimed.

## Verification results

- Full GitCore run: **88 tests passed**, 91.237 seconds. This includes the prior 75 and 13 new automatic-stash/line/drop-plan tests. [Full log](evidence/interaction-tests-full.log). The first focused 11-test pass is [also retained](evidence/interaction-tests-focused.log).
- After final drag routing changes, **3 additional headless application-store tests passed**, 4.846 seconds. [Routing log](evidence/interaction-drag-routing-tests.log). This is not a claim that all 91 ran together in one final full run.
- Final background build/launch passed. [Log](evidence/interaction-background-build-and-launch.log), [runtime check](evidence/interaction-background-verification.json), [signature](evidence/interaction-signature.log), [deployment target](evidence/interaction-deployment-target.log), [build timestamp checks](evidence/interaction-build-number-check.log).
- User preference changed during native acceptance: testing must not raise or activate apps. No further foreground app or browser interaction was performed after that request. Current verification runs with no SwiftUI scenes, no visible windows and activation prohibited. The recorded frontmost app remained Codex.
- No source commit, push or release. All Git acceptance writes used new disposable local repositories; no external server or personal project was modified.

## Tower reference

The installed Tower 18.0 (564) was inspected on `dist/InteractionReview-8ih3fag0/TowerReference`, separate from the Client repository used for GitPico writes.

- General preferences contains **Always offer to stash local changes**. [AX evidence](evidence/tower-autostash-preferences.txt).
- With a staged local edit and an untracked file, checkout opened **Stash Current Local Changes**. It offers an optional message, **Re-Apply Changes After Operation is Finished** (initially off), **Abort**, **Do Not Stash** and **Stash Changes**. The operation was aborted; Tower remained on main and its local changes were preserved. [AX](evidence/tower-autostash-checkout.txt), [screenshot](evidence/tower-autostash-checkout.png).
- The saved Layout.swift diff and its file/line controls were inspected. [Reference screenshot](evidence/tower-stash-lines-reference.png), [context evidence](evidence/tower-stash-lines-menu.txt). This does not establish that every custom Tower line-menu action was exercised.
- Official [Mac stash guide](https://www.git-tower.com/help/guides/working-copy/stash/mac) confirms automatic offers and file/partial-stash dragging. The [drag feature guide](https://www.git-tower.com/features/drag-and-drop) documents ref publication/integration/creation and commit reorder/folding/cherry-pick gestures. These are scope references; documented variants are not all native acceptance on this machine.

GitPico's new prompt follows the observed choices and default reapplication setting. Its stash details retain compact per-file headers and unified/split previews, with explicit gutter selection and review sheets. Exact typography, custom text interaction, tabs, drag previews and all Tower variants are not equivalent yet.

## Automatic stash implementation and tests

Before a dirty checkout/create-and-checkout, Pull/Sync, integration or interactive rebase, the app offers automatic stashing when enabled in preferences. The prompt can keep the saved stash or request reapplication. Saving includes tracked/index/untracked content. Restoring uses the captured immutable stash object and `--index`.

A per-worktree journal is written before saving. A unique message lets the next launch identify a stash saved just before an interruption. An independent recovery ref protects the saved object. During a Git conflict or interactive edit stop, restoration waits; successful Continue, Skip or Abort attempts it only after the operation ends. An apply attempt is journaled before Git runs. Interrupted or failed restoration becomes review-only and is never implicitly applied twice.

`AutomaticStashTests.swift` verifies:

- Checkout restores staged, unstaged and untracked content and retains pre-existing stashes.
- A rejected operation restores the draft and still reports the original failure.
- Saving without reapplication leaves a clean worktree and an applicable saved stash.
- A merge conflict survives repository reopening; Continue and Abort both restore the independent local draft afterward.
- Failed restoration persists a review record and saved content; a second operation and automatic replay are blocked.
- Interrupted-save discovery and protection of newly created local edits.
- Unborn save rejection leaves local files intact and does not start the requested operation.
- Fast-forward Pull against a local bare server preserves all local draft states.
- Interactive rebase Edit waits across reopening and restores only after Continue finishes.

Native checkout was also exercised before the background-only request. On main, Notes.txt was staged and Draft.txt untracked. The prompt's reapplication checkbox was enabled. Checkout changed HEAD to feature/sidebar, restored the exact staged Notes.txt and untracked Draft.txt, preserved the original stash and removed the finished journal. [Prompt](evidence/pico-autostash-prompt.png), [exact Git result](evidence/interaction-native-autostash.json).

### Recovery boundaries

This is not a filesystem transaction or a lock against external Git processes. A rejected/partial stash cleanup prevents the requested operation from starting and retains saved work. Failed stash application can leave partial working changes; the review banner preserves the stash and recovery ref. Users resolve/stage conflicts, then Finish Recovery, or keep the saved stash and end the recovery record. Finishing recovery never force-replaces a changed or ambiguous stash entry.

The journal covers the supported app operations, not arbitrary external commands. Stash reflog drop/clear still have the previously documented narrow external-process concurrency window. Ignored-file behavior remains native Git behavior. Recovery refs are not automatically pruned.

## Selected-line stash application

Both layouts use the existing patch-line IDs and gutter controls, with Shift range selection. Apply Selected Lines opens a review showing the stash, file and selected-line count. A selected patch is constructed against the saved base and applied only after a fresh immutable-preview comparison and Git's whole-patch check. The working copy changes; the index and stash are retained.

`StashLineTests.swift` covers LF/CRLF, missing final newlines, partial untracked-file creation, partial deletion, selections across multiple chunks, stale previews, invalid IDs and conflicting local content. A failed multi-chunk check leaves even the otherwise applicable first chunk untouched. Truncated chunks and structural/binary line selections are rejected; use whole files for those changes.

Native acceptance selected the deleted spacing=12 line and added spacing=14 line from a stash that also changes the title. Dragged **Drag Selected Lines** to Working Copy, reviewed and applied. Layout.swift ended with spacing=14 and the original Welcome title; the index still had spacing=12, and both stashes remained. [Selection screenshot](evidence/pico-stash-lines-selection.png), [drop review](evidence/pico-stash-lines-drop-review.png), [exact result](evidence/interaction-native-stash-lines.json).

## Drag implementation and acceptance limits

Supported source/target routes are wired to review actions:

- Working files, including multi-selection, to Stashes.
- Entire stash, selected files, individual file, chunk or selected lines to Working Copy.
- Ref/commit to Branches or Tags to create at the captured revision.
- Local branch/tag to a remote to review publication.
- Ref onto HEAD for Merge; Option chooses Rebase. Option on a remote ref offers tracking checkout.
- Commit onto HEAD for Cherry-Pick; Option chooses Revert.
- Commit onto a commit for a reviewed linear Squash/Fixup plan; row edges prepare reorder plans. Rebase plan rows can also reorder.

Drag data contains only a process-local token and repository-session UUID. The in-memory registry holds the immutable source object/preview. Different sessions, unknown IDs, unsupported targets and busy operations are rejected. Creating a review request does not itself perform Git writes.

An initial SwiftUI List drop target did not receive the source data: logs showed source creation without target delivery. A narrow AppKit `NSViewRepresentable` now registers the internal pasteboard type, validates the destination, draws a highlight and routes the drop. Ordinary clicks pass through. The final bridge handles source copy/move masks and clears target state when dragging ends. A competing List item-provider modifier was removed; source registration now uses one drag mechanism. [Runtime diagnostic log](evidence/interaction-drag-runtime.log).

Native file-to-stash acceptance succeeded after the bridge: dragging Notes.txt opened a selected-file Save Stash sheet. Draft.txt was also selected in that review, and saving **Native dragged files** left the Client clean. [Review screenshot](evidence/pico-drag-stash-review.png). Selected-line dragging back to the worktree also succeeded as described above.

**Native whole-list drag was still under investigation when foreground testing stopped.** The final source/mask adjustments were built and the request routes were tested headlessly; a subsequent native mouse walkthrough of whole-stash, branch, commit and rebase-row drops was not performed. Do not describe this as full drag parity or full native acceptance.

The three `GitPicoTests/DragRoutingTests.swift` tests load real NSItemProvider token data without opening windows and verify supported routes, exact full/file/chunk/line request payloads, branch/commit review requests, Option routing, cross-session rejection and busy/unsupported-target rejection. Core `RebaseDropTests.swift` verifies a reordered plan by executing it, and inspects Squash/Fixup plans on the current linear branch.

PR creation drops, committed-file changeset application drops, arbitrary multi-commit series and the complete Tower drag variant set remain missing. GitCore still enforces the existing root/merge/200-commit rebase boundaries.

## Background testing and version policy

The first background launch correctly stayed inactive but still had one visible restored window. A separate verification entry path now bypasses SwiftUI scene construction entirely, uses prohibited activation and never creates windows. The final check reports `isActive: false`, `visibleWindows: 0`, `version: 0.01`. This verifies bundle/process startup and the background guarantee; it is not interactive UI acceptance.

`script/build_and_run.sh --verify`, `--background`, `--logs` and `--telemetry` launch without activation. `--build-only` stages without launching. The normal user-invoked Run remains the interactive launch path. Project [AGENTS.md](../AGENTS.md) records both the no-foreground-testing preference and fixed marketing-version policy.

Final Client state is deliberately preserved: feature/sidebar, HEAD `32067995ae6770593341b8cd9c489cac1cf4d3ab`; one unstaged spacing-only change, index and Welcome title unchanged; both original and newly saved stashes retained. No automatic-stash journal is pending. [Final state](evidence/interaction-native-final-state.json). The running final development app is in background verification mode with no visible windows.

All screenshots directly linked above were visually inspected from saved files. No new foreground screenshot capture or app interaction occurred after the user's request to stop raising apps. macOS 26 runtime, complete keyboard/VoiceOver, large-repository performance and exhaustive appearance acceptance remain unverified. The [parity matrix](TOWER-PARITY-2026-10-24.md) retains these gaps explicitly.
