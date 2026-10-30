# Status bar sheen sweep — 2026-10-29

The user requested a sweeping-light treatment after reviewing the thin-line
motion preview. The decorative line is replaced with a full-height, soft-edged
reflection behind the status-bar content.

- A gradient band travels left to right across the existing bar, tilted by
  22 degrees, over 3.2 seconds. It loops outside the clipped bounds so the reset
  does not flash inside the bar.
- Soft-light blending and a vertical opacity mask keep the reflection brighter
  at the edges and softer behind text. Content and controls receive no position
  or size animation; the bar remains 28 points high.
- The existing 550 ms delay, 240/360 ms color transitions, stop-on-completion
  behavior, Reduce Motion handling and decorative-motion opt-out remain intact.
- The sweep does not express a completion percentage. It cannot intercept clicks
  or become an accessibility element.

[Final recorded preview](evidence/status-bar-sweep-20261029/status-bar-sweep.gif),
[motion disabled](evidence/status-bar-sweep-20261029/reduced-motion.gif).

The GIFs use actual hidden native-window captures during Fetch against a
sleep-delayed upload-pack in a disposable local bare repository. Native toolbar
layout and the first sweep capture passed; the final gradient/mask capture passed
separately. The motion-disabled capture also passed and uses the same disabled
rendering branch, without changing system preferences. Each capture asserts no
activation and zero visible windows.

The final recording's lower-bar background changes as the sweep passes; it stays
uniform in the disabled recording. Both pixel traces and test summaries are
retained beside the previews. The staged debug application also passed background
and native-startup checks; see
[launch-summary.json](evidence/status-bar-sweep-20261029/launch-summary.json).

The GIF preview is scaled and resampled to 12 fps from offscreen PNGs, so it does
not establish full display-rate smoothness. Host: macOS 27.2 arm64. Foreground
interaction, VoiceOver, a live system-preference toggle, performance profiling
and macOS 26 runtime compatibility are not acceptance-tested. No personal
repository or external server received acceptance writes. No commit, push,
installed MacBook replacement or release is included in this request.
