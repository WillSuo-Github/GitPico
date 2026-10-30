# Soft status tint and one activity entry — 2026-10-30

## Design and behavior

This revision supersedes the full-accent background used in the earlier quiet
transition preview. The status bar remains 28 points high. While a manual
operation is running, the existing bar material gets a 6% accent tint in light
mode and a 10% tint in dark mode. Branch, working-copy summary, path and update
time keep their normal semantic foreground colors.

The permanent 148-point Activity entry uses a slightly stronger accent fill
(12% light / 20% dark), a fine border, medium-weight operation name and the
existing native progress indicator. The operation name uses the primary text
color in both appearances. Only state transitions fade (200 ms in / 300 ms
out); there is no sweep, looping decoration or layout animation. System Reduce
Motion, or the scoped motion opt-out used in validation, disables those fades.

There is one Activity entry in the bottom bar. The separate Network entry is
removed. Activity opens the latest manual operation's summary, or the latest
network record for this repository when no manual result is present. The
Network Activity link is always available, including the empty state and after
clearing a manual result. Existing network history, cancellation, authentication
and matching-manual-record navigation remain available through that link.
The entry also remains available while choosing a repository.

Success briefly changes the activity icon to a check, then restores the ordinary
icon; the result remains inspectable. Failure/warning retains Review with a
local warning treatment until cleared or replaced. Neither state replaces the
branch or working-copy summary. Background fetch does not tint the bar or
replace the latest manual result.

## Evidence and limits

- Captures run real Fetch, Pull and Push against disposable local repositories,
  plus a failed Fetch against a nonexistent local remote. No personal repository
  or external server receives acceptance writes.
- Main-window captures use hidden native windows in light/dark mode at 1440 and
  1080 points wide. Details captures render the actual popover content in a
  hidden host; they do not prove native popover positioning or mouse/keyboard
  dismissal behavior.
- The animated preview is assembled from captured native frames. It is not a
  foreground recording or display-rate performance measurement.
- Checks assert no app activation and zero visible windows. Host: macOS 27.2
  arm64. Foreground interaction, VoiceOver and macOS 26 runtime acceptance are
  not claimed.
- Six final focused checks passed with zero failures: native Fetch/Pull/Push and
  details captures, motion capture, toolbar layout, retained result/log routing,
  quiet background fetch and failed-fetch retry. The separate motion-disabled
  capture passed (one check, zero failures). See
  [check summary](evidence/soft-activity-20261030/check-summary.json) and
  [motion-disabled summary](evidence/soft-activity-20261030/reduced-check-summary.json).
- Pre-release application regression passed: 197 passed, 23 opt-in checks
  skipped, zero failures. See
  [release regression summary](evidence/soft-activity-20261030/release-regression-summary.json).
- `./script/build_and_run.sh --verify` passed; both background and native-startup
  verification report no activation and zero visible windows. See
  [launch summary](evidence/soft-activity-20261030/launch-summary.json).

[Recorded transition](evidence/soft-activity-20261030/soft-activity.gif).
[Running](evidence/soft-activity-20261030/02-running.png).
[Dark running](evidence/soft-activity-20261030/02-running-dark.png).
[Completed](evidence/soft-activity-20261030/03-completed.png).
[Activity summary](evidence/soft-activity-20261030/04-details.png).
[Network-only summary](evidence/soft-activity-20261030/05-network-history.png).

The captures above record local implementation validation. Distribution is
tracked separately in the release manifest and published GitHub Release. No
installed MacBook replacement or foreground acceptance is claimed here.
