# Native repository window tabs design QA

final result: blocked

## Scope and evidence

The user selected concept 1: native macOS window tabs below the complete toolbar. This pass covers repository/window chrome and switching. It does not replace the existing working-copy editor, staging controls, repository navigation or saved diff-layout preference with the illustrative mock editor.

- Source visual truth: `docs/design/native-window-tabs-target.png` (1586 × 992 pixels, generated concept, no CSS or measured point specification).
- Implementation: `docs/evidence/native-window-tabs/native-tabs-1440-light.png` (2880 × 1800 pixels, 2× native bitmap; outer window 1440 × 900 points).
- Additional viewports: 1080 × 900 points, light and dark appearance. These are hidden native AppKit windows; no browser or foreground capture was used.
- Normalization: source aspect-fit into 1440 × 900 pixels; implementation downsampled to 1440 × 900 pixels; no aspect-ratio distortion. Source and implementation have slightly different aspect ratios. Neither exact text-pixel measurements nor subpixel color comparisons are claimed.
- State: three real disposable repositories, GitPico active, Costaware-iOS and Website inactive, three changed files, one staged README, selected Swift file and retained commit subject. The source uses a unified diff; the implementation retains the current split-diff preference. Fixture line numbers and code length differ.
- Full-view comparison opened together: `docs/evidence/native-window-tabs/comparison-full.png`, source left / implementation right.
- Focused toolbar/tab comparison opened together: `docs/evidence/native-window-tabs/comparison-window-chrome.png`, source left / implementation right.

## Findings

- [P2, validation blocker] Active native material and focus appearance cannot be judged from the suppressed-window bitmap. The selected sidebar row renders as a black block, while inactive controls are pale. This is visible in the combined comparison. It is not sufficient evidence to classify the live foreground appearance as correct or broken. Keep final visual acceptance blocked until an authorized foreground view is available; do not replace system selection colors merely to alter an offscreen capture. Background-only testing remains the user's explicit constraint.
- Expected native-platform difference: macOS 27 draws rounded native tab contours instead of the mock's classic connected-tab corners. AppKit owns this appearance. The selected direction is real native window tabs, so no custom tab-shape imitation is introduced.
- Expected retained product details: the source's illustrative Commit/Amend toolbar actions differ from the app's existing Actions, navigation and integration menus. Existing behavior remains, with compact Actions / Undo / Redo / Stash / Apply captions and system icon-and-label presentation. The complete toolbar has all 16 custom controls visible at 1440 points. At 1080 points AppKit places one control in its standard overflow; tabs do not consume toolbar width.
- Existing editor density, sidebar sections and split-diff preference differ from the concept. They are outside this repository-tab change and were retained deliberately. No claim of a pixel-for-pixel full-editor clone is made.

## Required fidelity surfaces

- Fonts/typography: real AppKit/SF system controls, native tab titles and tooltip paths. All three repository names are readable in the focused capture; no custom font or rasterized UI text. The generated target's exact font metrics cannot be inferred reliably; inactive contrast and antialiasing are not accepted from this capture.
- Spacing/layout: tabs span the full window below the toolbar; repository navigation begins below them. Sidebar repository-switcher rows are removed. Both 1080- and 1440-point layouts render without custom tab overlap. Normal native overflow applies at the narrow size. Existing editor column proportions are retained.
- Colors/tokens: system light/dark materials, labels and SF Symbols follow macOS. White document regions and semantic red/green diffs remain. Selected-row/focus colors are blocked by the offscreen artifact above.
- Image quality/assets: native SF folder/grid icons and native toolbar symbols are vector system assets. No mock screenshot is painted into the app, and no placeholder artwork substitutes for UI. Captured bitmaps are 2× PNG without lossy compression; black selection artifacts are explicitly excluded from acceptance.
- Copy/content: repository titles are GitPico / Costaware-iOS / Website; empty tabs are Repositories. User-facing actions retain their existing meanings and review flows. Temporary repository paths and fixture contents are dynamic evidence, not shipped sample UI.

## Comparison history

1. Initial native capture, retained in the combined `docs/evidence/native-window-tabs/comparison-window-chrome-before.png`, exposed a P1 structural mismatch: SwiftUI's full-height sidebar extended alongside the tab strip, leaving tabs only over the detail area. Removed fullSizeContentView from RepositoryNativeWindow and set sidebar NSSplitViewItems.allowsFullHeightLayout to false through the existing hosting hierarchy. The revised capture and focused comparison show a full-width tab strip with the sidebar starting below it.
2. The first capture fixture assigned file selection before the native List finished initializing, producing an empty diff and failing the preservation assertion. The fixture now settles the hosted view before simulating selection; the post-fix capture renders the real selected-file diff and passes selection/host/draft preservation. This was a fixture correction, not an unverified product selection patch.
3. Post-fix full and focused comparisons confirm the structural correction. The inactive selection-material capture blocker remains; there is no foreground visual verdict.

## Interaction evidence and limits

Three native lifecycle tests cover model/native selection, new-tab responder routing, busy close rejection, corrupt-draft close protection, last-chooser close/reopen, tab reorder, detached groups and source-group repository opening. The opt-in render test covers light/dark at two widths and stable hosted content/draft/file selection after native cycling. Separate real-App startup verification exercises actual menu creation and New Tab / Close Tab actions with all windows suppressed.

Foreground mouse drag, keyboard focus, VoiceOver, live material appearance and macOS 26 runtime acceptance have not been exercised. Tests run on macOS 27.0.1; deployment remains 26.0.

## Implementation checklist

- [x] Replace custom sidebar repository tabs with NSWindow tabs.
- [x] Preserve the complete toolbar and per-repository hosting/store state.
- [x] Fix tab strip/sidebar structural alignment and recapture both widths/themes.
- [x] Exercise native lifecycle and actual menu startup without activation.
- [ ] Confirm foreground active selection/material and real mouse behavior when foreground testing is authorized.

## 2026-10-25 follow-up: titlebar safe-area correction

The earlier removal of fullSizeContentView is superseded. A user foreground screenshot exposed a real titlebar material overlay covering the picker heading. The issue was reproduced in a suppressed native window: the titlebar background occupied the first 66 points of content while the hosting view had a zero top safe-area inset.

The final correction restores fullSizeContentView and uses the balanced split style. The root hosting safe-area inset is now 66 points in the same single-tab fixture. The heading is clear in `docs/evidence/titlebar-overlay/after/repository-picker-dark.png`; compare against the before image in `docs/evidence/titlebar-overlay/picker-header-comparison.png` (both 1440 × 980 points, 2×, header crops normalized to 1×). Toolbar background hiding, scroll-edge hiding and tracking-separator removal experiments were ineffective or changed control placement and were reverted.

Four focused native tests passed and the packaged app passed both suppressed startup verifiers. The complete toolbar remains available. Native tabs now follow the sidebar/detail partition rather than spanning the sidebar as the generated target shows. That full-width visual target remains unmet; no full-design acceptance is claimed. Existing inactive selection-material / foreground focus acceptance gaps remain. The report's overall final result remains blocked; the specific reproduced picker-title overlay is fixed in the background comparison.

## 2026-10-25 follow-up: unified search

Removed the independent wand toolbar item and integrated Quick Actions into the native toolbar search field. The final suppressed native toolbar capture has 15 visible controls at 1440 points. Search suggestions were inspected in light/dark after replacing ImageRenderer-only capture (which omitted ScrollView rows) with a suppressed native NSHostingView capture. Keyboard, marked-text deferral, contextual Return safety, cache reuse and stale-result guards passed background integration tests. The packaged real-App menu verifier confirms both Find and Quick Actions reach the same field with zero visible windows and no activation. See `docs/VALIDATION-UNIFIED-SEARCH-2026-10-25.md`. Foreground popup anchoring/mouse/assistive-input acceptance and the existing overall visual-parity blockers remain unverified; this follow-up does not change the overall verdict.

## 2026-10-25 follow-up: design refresh

All primary destinations were re-laid out and restyled (brand accent, shared components, toolbar/sidebar information architecture). Suppressed native captures for 12 pages in light and dark are compared before/after in `docs/evidence/design-refresh/`. The existing offscreen artifacts remain (black sidebar selection, inactive-window prominent buttons), so foreground material, focus and mouse acceptance are still unverified; the overall verdict stays blocked. See `docs/VALIDATION-DESIGN-REFRESH-2026-10-25.md`.
