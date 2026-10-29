# Bottom status feedback — 2026-10-29

The user requested a colored bottom status bar while operations run, returning
to its existing background when idle, to avoid the content displacement caused
by the new top operation banner.

- Ordinary operation feedback no longer inserts a banner above repository content.
- The existing bottom status bar remains 28 points high in every operation phase.
- Busy operations use the system accent color across the bar, with a semibold
  operation label, progress indicator and elapsed time where available. Text
  contrast is selected against the resolved accent color in light/dark mode.
- Idle and completed states use the original bar material. Completion, failure
  and actionable warnings appear inline; existing feedback persistence,
  dismissal and Network Activity access remain available.
- Existing conflict/recovery panels retain their contextual behavior. This trial
  does not claim that opening those panels never changes layout.

## Evidence

[Idle](evidence/bottom-status-feedback-20261029/idle.png),
[Fetching](evidence/bottom-status-feedback-20261029/fetching.png),
[dark Fetch](evidence/bottom-status-feedback-20261029/fetching-dark.png),
[completed](evidence/bottom-status-feedback-20261029/completed.png),
[full window](evidence/bottom-status-feedback-20261029/repository-fetching.png).

The native capture exercises actual Fetch, Pull and Push against a disposable
local bare repository with delayed upload-pack/pre-push helpers. It asserts no
activation and zero visible windows. The capture and existing native toolbar
layout check both passed; see
[capture-summary.json](evidence/bottom-status-feedback-20261029/capture-summary.json).

The top edge of the Changes header was measured using Vision OCR in equal-sized
2880 × 1800 native screenshots, not accessibility geometry. The previous top
banner moved that header from approximately 131.6 to 223.6 pixels (46 points at
2× scale). The revised idle, running and completed captures put it at
approximately 131.6, 131.5 and 131.6 pixels; the subpixel difference is OCR
estimation noise. See
[content-position.json](evidence/bottom-status-feedback-20261029/content-position.json).

Captures are from a hidden native window on macOS 27.2 arm64. Inactive sidebar
selection can show a renderer artifact. These are not foreground mouse,
VoiceOver or macOS 26 compatibility acceptance. No personal repository received
acceptance writes. Before release preparation, five focused checks passed:
the real-operation capture, toolbar layout, failed Fetch/retry, cancelled Fetch,
and successful Commit with an Undo warning. See
[release-check-summary.json](evidence/bottom-status-feedback-20261029/release-check-summary.json).
Distribution is tracked separately in the release manifest and GitHub Release;
these captures do not imply that the installed MacBook application was replaced.
