# AI commit message validation — 2026-10-27

Build: `0.01 (20261027113905)`. Host: macOS 27.0.1, arm64. Minimum deployment target remains macOS 26.0; this is not macOS 26 runtime acceptance.

## Delivered behavior

- A sparkles button beside the Working Copy commit summary opens AI Commit Message after changes are staged.
- Users choose Codex CLI, Claude Code, Antigravity (`agy`), or GitHub Copilot CLI, plus English or Simplified Chinese. Executable detection includes PATH, Homebrew and common home-directory installation paths; explicit executable paths are supported.
- The selected tool, language and per-tool executable overrides persist in `Application Support/GitPico/ai-commit.json` without storing credentials.
- GitPico supplies the staged diff, disables external Git diff/textconv drivers, and runs the CLI in a private temporary directory. The sheet explains use of the CLI's existing login/model and possible subscription/API consumption before generation.
- Generated messages are editable previews. Use Message / Replace Draft explicitly fills the commit editor. It does not create a commit.
- Index, branch, HEAD, repository-session, amend-mode and current-draft checks reject stale suggestions. Cancellation, a two-minute timeout, output bounds and unavailable/login-failure handling retain the current commit draft. Input diffs are limited to 96 KB.

## Evidence

- Native Xcode focused integration run: **9 test functions passed**, including a four-provider parameterized stub test. It verifies staged-only input, untouched index/HEAD, disabled diff drivers, unborn/binary/renamed files, size limits, output parsing, literal executable/argument handling, timeout/cancellation, explicit application, stale-result rejection and preferences persistence/corruption handling.
- Opt-in real CLI run: **all four provider cases passed** using a small synthetic staged README change in disposable repositories. Each provider returned a parsed message and retained the same staged fingerprint. No GitPico source was supplied to those requests.
- Complete app-target regression: **146 passed, 19 conditional skips, 0 failures** (165 test functions in the Xcode result summary; parameter cases are not counted again).
- Offscreen native captures verified the commit entry, initial provider sheet and editable generated suggestion. The capture test confirmed no visible app windows and no activation. No foreground mouse interaction was performed.
- `./script/build_and_run.sh --verify`: build, staged bundle signature verification, background launch and native startup/menu checks passed; both launches reported zero visible windows and no activation.
- `git diff --check`: passed.

Temporary logs: `/tmp/gitpico-ai-commit-focused-tests.log`, `/tmp/gitpico-ai-commit-live-tests.log`, `/tmp/gitpico-ai-commit-app-regression.log`, `/tmp/gitpico-ai-commit-verify.log`. Offscreen captures: `/tmp/gitpico-ai-commit-render/`.

The real-CLI and capture tests are opt-in via `TEST_RUNNER_GITPICO_VERIFY_AI_COMMIT_LIVE=1` and `TEST_RUNNER_GITPICO_RENDER_AI_COMMIT=1`, respectively. Live generation can consume provider allowance; the default test suite uses local stub executables.
