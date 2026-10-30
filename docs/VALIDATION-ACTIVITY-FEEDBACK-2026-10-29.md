# On-demand operation feedback — 2026-10-29

## Current-run finding and interaction

The user reported that the completion message replaced repository information
for several seconds. Current-run hidden native captures reproduce it:
[1. idle](evidence/activity-feedback-20261029/01-before-idle.png) shows the branch
and working-copy summary; [2. completed](evidence/activity-feedback-20261029/02-before-completed.png)
replaces those fields with Fetch · Completed. The bottom bar stays vertically
stable, but the information the user was reading disappears. Success has the
same prominent placement as work in progress or a failure requiring attention.

The revised interaction keeps branch, change count, path, update time and
Network access in their existing roles. A permanent 148-point Activity button
owns the transient state; its allocated width does not change between phases.
The bar remains 28 points high.

1. **Running:** retain repository information, use the existing accent-colored
   bar, and show a progress indicator and compact task name in Activity. Hover
   reveals the full title; opening Activity reveals the current task and elapsed
   time. [Running](evidence/activity-feedback-20261029/03-running.png),
   [dark/narrow](evidence/activity-feedback-20261029/03-running-dark.png).
2. **Completed:** restore the normal background immediately. Activity briefly
   shows a green check for two seconds, with no completion sentence replacing
   the branch or working-copy fields.
   [Completed](evidence/activity-feedback-20261029/04-completed.png).
3. **Settled / inspect:** the check returns to the ordinary Activity icon, but
   the latest result remains inspectable. Opening the popover shows the result,
   start time, duration and relevant Network Activity link. Closing the panel
   retains the result; Clear removes it. Network Activity selects the matching
   record, including after a newer background Fetch has been recorded.
   [Settled](evidence/activity-feedback-20261029/05-settled.png),
   [details content](evidence/activity-feedback-20261029/06-details-content.png).
4. **Failure / warning:** keep a Review indicator until explicitly cleared or
   replaced by another manual operation. Details contain the captured diagnostic
   without replacing repository information.
   [Failure details content](evidence/activity-feedback-20261029/07-failure-details-content.png).

The latest result is a per-repository in-memory result, retained until the next
manual operation, repository change or explicit Clear. Existing persisted
Network Activity history remains available. Existing Git error alerts and
conflict/recovery panels retain their behavior. This change does not add local
operation-history persistence or change write guards.

## Verification and limits

- App regression: **197 test definitions passed, 22 opt-in definitions skipped,
  zero failures**. See [regression-summary.json](evidence/activity-feedback-20261029/regression-summary.json).
- Six final focused checks passed after the compact-label and log-selection
  refinements. They include retention after the acknowledgement ends, matching
  the original operation's log after background Fetch, selection reset after
  dismissal, local staging, failure/retry, cancellation, native toolbar layout
  and capture. See [final-check-summary.json](evidence/activity-feedback-20261029/final-check-summary.json).
- The staged debug app passed background and native-startup verification with
  no activation and zero visible windows. See
  [launch-summary.json](evidence/activity-feedback-20261029/launch-summary.json).
- The final capture passed separately after fitting the details preview to its
  natural height. See [capture-summary.json](evidence/activity-feedback-20261029/capture-summary.json).
- Actual Fetch, Pull, Push and a rejected Fetch use disposable local repositories.
  No personal repository or external server receives acceptance writes.
- The app-window captures are real hidden native-window captures. Details images
  render the same popover content in a hidden host without presenting a native
  popover or error alert. Native popover positioning, click-outside/Escape
  dismissal, foreground sheet transitions and VoiceOver are not acceptance-tested.
- The fixed Activity button has a text label, symbol, full-title help and
  accessibility value. State is not communicated by color alone. The screenshots
  support layout/discoverability findings, not full accessibility compliance.
- Host: macOS 27.2 arm64. No macOS 26 runtime acceptance or installed MacBook
  replacement is claimed. Inactive sidebar selection may have a capture artifact.

This is a local implementation and review preview. No commit, push or release is
part of this request.
