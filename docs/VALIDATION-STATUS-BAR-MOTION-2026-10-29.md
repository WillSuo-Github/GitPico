# Status bar motion — 2026-10-29

The user requested motion when the status bar changes color. This builds on the
uncommitted Activity design without changing operation execution or feedback
retention.

- Crossfade the accent background in over 240 ms and out over 360 ms. Foreground
  color animation is scoped to color modifiers; the bar, labels and controls do
  not receive layout or position animations.
- After 550 ms of continuous work, reveal a two-point gradient line at the top
  of the bar. It travels slowly over 2.8 seconds and loops outside the visible
  bounds. It communicates activity, not a percentage or estimated completion.
- Remove the line when the operation ends; idle bars do not retain a looping
  animation. Decorations are clipped to the existing 28-point bar and cannot
  intercept clicks or become accessibility elements.
- System Reduce Motion disables the color transitions and decorative line.
  The scoped repositoryStatusMotionEnabled environment value also lets embedded
  views and previews opt out without changing macOS settings. It cannot override
  the system Reduce Motion preference. Standard progress indication remains.

## Preview and verification

[Recorded motion](evidence/status-bar-motion-20261029/status-bar-motion.gif),
[decorative motion disabled](evidence/status-bar-motion-20261029/reduced-motion.gif).

Both recordings contain actual hidden native-window frames around a real Fetch
against a disposable local bare repository with delayed upload-pack. The GIFs
are assembled from captured PNGs with their recorded timestamps, scaled to
1440 pixels wide and resampled to 12 fps. They are not a foreground screen
recording or proof of full display-rate smoothness.

Two focused checks passed: native toolbar layout and retention of the completed
result/log selection after its acknowledgement ends. Normal and motion-disabled
capture checks passed separately; all assert no activation and zero visible
windows. The disabled capture uses the scoped motion opt-out, exercising the
same rendering branch as system Reduce Motion, without modifying user settings.

Pixel measurements on the decorative line show moving highlight positions in
normal busy frames and a constant position in the disabled recording. The
measurements are retained next to the clips, together with the test summaries.
The staged debug app also passed background and native-startup verification;
see [launch-summary.json](evidence/status-bar-motion-20261029/launch-summary.json).

Host: macOS 27.2 arm64. No foreground interaction, live system-preference toggle,
VoiceOver, performance profile or macOS 26 runtime acceptance is claimed. This is
local preview work; no commit, push or release is included in this request.
