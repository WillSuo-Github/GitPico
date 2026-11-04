# GitHub workflow authorization — 2026-11-04

Validated staged build: **20261104174024**. Marketing version remains `0.0.1`; minimum macOS remains `26.0`. The host was macOS 27.2, so this is not runtime acceptance on macOS 26.

## Cause and repair

GitHub rejected the supplied Push because its OAuth grant lacked `workflow` permission while the commits changed `.github/workflows/source-catalog.yml`. The previous GitPico device authorization requested repository/profile access and token renewal, but omitted this separate capability.

- GitHub.com and Enterprise device authorization now request `repo`, `workflow`, `read:user` and `offline_access`. GitLab permissions remain unchanged.
- Interactive sign-in and account saving both require a GitHub grant with repository and workflow access. A partial grant cannot silently create an account or replace an existing credential.
- Existing OAuth grants still refresh with their original repository permissions. Adding the requested scope to the app does not silently grant it to an existing token.
- Authentication describes the additional access and directs existing accounts to **Sign In Again**. Reconnect verifies the same host/provider/account and preserves its profile UUID and all repository assignments.
- The GitHub workflow-scope rejection now has specific recovery advice in Network Activity and the operation feedback panel, covering OAuth reconnect and personal-token permission updates.
- No failed write is retried automatically.

Existing users should open **Settings → Authentication**, find the GitHub account assigned to the affected repository, choose **Sign In Again…**, and approve the requested workflow access on GitHub. Then retry Push explicitly.

References: [GitHub OAuth scopes](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps), [GitHub authorization and device flow](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps).

## Verification

- Focused repair tests: **8 passed, 0 failed**; `/tmp/GitPico-OAuthWorkflow-Focused-20261104.xcresult`.
- OAuth/authentication regression plus suppressed panel capture: **29 passed, 3 skipped, 0 failed**; `/tmp/GitPico-OAuthWorkflow-Regression-20261104.xcresult` and `/tmp/gitpico-oauth-workflow-regression-summary.json`. The skipped cases require explicit real Keychain/public-client probes.
- The actual outgoing mock device request contains `workflow`; a grant without it is rejected before identity lookup or credential saving. Full grants are accepted.
- A legacy GitHub grant can still refresh without workflow access. Interactive reconnect upgrades the same profile and retains two existing repository assignments.
- Declined authorization, missing workflow permission and a different returned account retain the old access/refresh tokens and unchanged account metadata. Tokens remain absent from account settings.
- Existing GitLab PKCE, callback validation, cancellation, identity validation, renewal and personal-token compatibility tests passed.
- Authentication consent text inspected in light/dark suppressed native captures: `/tmp/gitpico-oauth-workflow-panels/authentication-light.png` and `authentication-dark.png`. The capture test asserts no visible windows and no app activation.
- `./script/build_and_run.sh --verify` passed. Both application and native startup reports show build `20261104174024`, `isActive: false`, and `visibleWindows: 0`. Staged app: `dist/GitPico.app`.

No real account was authorized or renewed, and no Upovi repository config or remote was modified. GitHub consent and a subsequent real Push remain user steps; mock transport tests do not establish live write acceptance.
