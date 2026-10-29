# Branch drag-to-merge — 2026-10-29

Drag a branch row onto the currently checked-out branch to open a merge review.
The review identifies the source branch, current destination branch and source
commit. Dropping only opens the review; confirming runs the existing merge and
local-change protection flow. Other destination branches reject the drop, so
this interaction does not switch branches.

## Native source interoperability

The previous private identifier was `com.willsuo.GitPico.drag`. In an offscreen
native sidebar, the actual row pasteboard writer offered
`com.willsuo.gitpico.drag`, while the receiver requested the mixed-case name.
The test could not read the exported payload using the receiver's identifier.
Manually constructing tokens for destination tests did not exercise this source
conversion.

The exported Info.plist type, provider and receiver now share the lowercase
identifier. Sidebar reference rows use the list's native
[item-provider trait](https://developer.apple.com/documentation/swiftui/view/itemprovider(_:))
and fill the available row width. Tokens remain private to the process and
repository session. The receiver also rejects integration drops during an
existing Git operation.

## Verification

- An offscreen sidebar test obtains the actual NSOutlineView row pasteboard
  writer, reads its exported payload using the destination's identifier, feeds it
  through the native destination lifecycle and confirms that the review appears
  before any Git mutation. Confirmation fast-forwards only the current branch;
  the source branch remains unchanged.
- A second disposable-repository test rejects another destination branch, starts
  a conflicting merge onto the current branch, rejects further integration
  drops during that merge and aborts it. HEAD, branch and original file content
  return to the pre-merge state.
- Existing destination tests cover duplicate callbacks, stale sessions, external
  HEAD switches, Stash/file payloads and commit/rebase drops.
- Full app regression and packaged background/native-launch summaries are in
  [evidence/branch-drag-merge-20261029](evidence/branch-drag-merge-20261029).

Validation runs on macOS 27.2 arm64 with hidden windows and no app activation.
Git writes use disposable local repositories. No foreground mouse drag or
macOS 26 runtime acceptance was performed. The MacBook installation was not
replaced. Marketing version remains 0.0.1 and the deployment target remains 26.0.
