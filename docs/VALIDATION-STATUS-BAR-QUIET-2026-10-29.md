# Restrained status transition — 2026-10-29

The user found the full-height sweep too conspicuous. The final direction
removes the sweep, moving line, highlights, delayed task and repeating animation.
Only state changes animate: a 200 ms accent fade-in and a 300 ms return to the
normal bar material. During execution the background stays uniform; the existing
small progress indicator and operation name communicate ongoing work.

[Recorded preview](evidence/status-bar-quiet-20261029/status-bar-quiet.gif).

The existing fixed-height bar, permanent repository information, Activity entry,
result retention and Reduce Motion behavior are preserved. Animation remains
scoped to foreground colors and the background opacity; no content-size or
position animation is introduced. Earlier motion/sweep evidence is retained as
historical exploration, not the current implementation.

Actual hidden native-window captures exercise Fetch against a disposable local
bare repository. The normal capture and native toolbar layout checks passed;
the motion-disabled capture passed separately. All assert no activation and
zero visible windows. Steady running frames show one uniform background color
and an unchanged highlight position, confirming the repeating sweep is absent.

The preview uses captured PNGs, scaled and resampled to 12 fps. It is not a
foreground recording or a full display-rate performance test. The motion-disabled
capture uses the same rendering branch as system Reduce Motion without changing
user preferences. Host: macOS 27.2 arm64; VoiceOver, live system-preference changes,
foreground interaction and macOS 26 runtime acceptance are not claimed.

The staged debug application's background and native-startup results are in
[launch-summary.json](evidence/status-bar-quiet-20261029/launch-summary.json).
No commit, push, installed MacBook replacement or release is included here.
