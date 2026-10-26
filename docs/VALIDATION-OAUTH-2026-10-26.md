# GitHub and GitLab OAuth — 2026-10-26

Build: **0.01 (20261026150348)**. Minimum macOS **26.0**; validation host **27.0.1 / arm64**. This implementation is an uncommitted working-tree batch after `4b181cf`; [source hashes](evidence/oauth-2026-10-26/source-sha256.txt) identify the checked files. Existing historical validation reports retain their original scope.

## Actual app registrations

The user explicitly requested registration and completed Chrome sign-in/security verification. Both registrations succeeded through the providers' own settings UI:

| Provider | Owner | Registration | Native flow | Callback |
| --- | --- | --- | --- | --- |
| GitHub.com | WillSuo-Github | [GitPico app 3964716](https://github.com/settings/applications/3964716) | Device Flow enabled | `gitpico://oauth/github/callback` (registered; device flow does not consume it) |
| GitLab.com | willsuosuo | [GitPico app 6291928](https://gitlab.com/oauth/applications/6291928) | Public client / PKCE, Confidential disabled | `gitpico://oauth/gitlab/callback` |

Public IDs and settings are in [registered-apps.json](evidence/oauth-2026-10-26/registered-apps.json) and bundled in `OAuthAppCatalog`. No client secret is embedded or needed by either chosen flow. GitLab generated a server-side secret on registration; it was not copied into files or used by the app. The registration screenshots were saved after leaving that one-time secret page: [GitHub](evidence/oauth-2026-10-26/github-registration.png), [GitLab](evidence/oauth-2026-10-26/gitlab-registration.png).

A real unauthenticated call using the bundled GitHub Client ID successfully obtained a device challenge. [Probe result](evidence/oauth-2026-10-26/github-device-registration-probe.json) records acceptance without saving device/user codes, opening a browser, granting account access or storing an access token. This verifies the registration/device endpoint, not account authorization or repository access. The challenge expires normally without approval.

## Implemented user flow

Settings → Authentication and Repository → Authentication provide:

- **Sign In with GitHub**: request a device challenge, open the provider's validated HTTPS verification page, display the one-time code with Copy/Open actions, and poll at the provider's interval. Pending authorization waits; slow-down increases the interval. Denial, expiration and cancellation end the flow without saving an account. Requested scopes: `repo`, `read:user`, `offline_access`.
- **Sign In with GitLab**: native `ASWebAuthenticationSession`, random state and S256 PKCE, exact callback matching, one-time code exchange and a five-minute browser timeout. GitLab requests `read_user` and `write_repository`. Browser callbacks/cancellation carry generation identifiers so an old completion cannot finish a later session. The callback URL scheme is registered in the source Info.plist; its date build is still generated into DerivedData.
- After exchange, validate required repository scopes and request the provider's current account. GitLab OAuth uses an Authorization Bearer header, while existing PAT verification retains PRIVATE-TOKEN. Only a verified identity is saved. Reconnect preserves the profile UUID/repository assignments and rejects a different account or stale metadata. A flow retains its original repository assignment target; closing its view cancels it.
- Connected accounts and Clone/repository pickers distinguish OAuth from manual tokens. Existing metadata and Keychain PAT records decode without OAuth fields. Manual Token Update cannot replace an OAuth credential's renewal state. Other HTTPS hosts still support manual PAT profiles; enterprise/self-managed OAuth app configuration is not exposed in this batch.
- Remove deletes the local credential. Provider grants are revoked separately through the linked Authorized Apps settings. No provider permission is approved automatically.

## Credential renewal and transport behavior

Access token, refresh token, expiry, scopes and issuer/client configuration live in the existing app-owned Keychain item. Account metadata contains names, hosts, method and assignments, not tokens. Keychain access remains noninteractive. No client secret is used, and temporary grants/verifiers are not logged.

The per-command, exact-host HTTPS Git helper checks expiry and renews on demand before returning an access token. It returns no refresh token. GitLab's conventional `oauth2` username is supported for OAuth credentials; other explicit user mismatches remain rejected. Existing system SSH and unrelated HTTPS hosts do not have to renew the selected OAuth profile just to start a transport.

Renewal uses a private cooperating file lock across helpers/windows, re-reads Keychain after obtaining it, rotates tokens once, and saves the new pair before releasing the lock. A renewal already sent to the provider completes its bounded exchange/save even if its caller is cancelled; cancellation before obtaining a lock stops normally. Removed or concurrently changed credentials are not resurrected. Invalid/expired refresh grants report the need to sign in again. Losing Keychain write access after server rotation requires sign-in again; the error does not claim the old token remains usable.

HTTP exchanges require HTTPS, use ephemeral URLSession storage, reject redirects, cap response data at 128 KiB and apply bounded timeouts. State, duplicate code/state fields, callback scheme/host/path, token type, scope, secret size and expiry are validated. Network logs redact OAuth token prefixes, refresh-token/verifier/device-code assignments and GitLab's 64-hex token form; active credential secrets are refreshed in the observation's redaction list. The helper reports sanitized authentication errors on stderr and never logs the credential protocol output.

## Background checks and failure evidence

[Run record](evidence/oauth-2026-10-26/test-runs.json), [selected result lines](evidence/oauth-2026-10-26/checks.txt):

- Initial focused OAuth Core run: **9 reported tests passed**, 0.121 seconds.
- Full GitCore run: **227 reported tests passed**, 263.737 seconds. A later cancellation-preservation case was added; the final focused Core run contains **13 passing tests**, 0.597 seconds, including that new case, OAuth parsing/PKCE/device behavior, concurrent rotation, unused HTTPS credentials, helper restrictions and network cancellation. The combined coverage is 228 unique Core cases, not 240 independent cases.
- Final complete App run: **144 tests reported passed**, 66.841 seconds; the runner also reports **12 opt-in tests skipped**. These are not 144 foreground UI journeys. All new fixture login tests ran, plus real temporary PAT/OAuth Keychain helper tests and suppressed panel captures. The registration probe was explicitly enabled in the earlier full run, then skipped on the final run to avoid issuing extra challenges.
- App cases cover GitLab PKCE exchange with Bearer identity verification before persistence, GitHub device login, partial scopes, malformed identity, user denial, mismatched state, cancellation, binding retention, reconnect identity rejection, stale metadata rollback and legacy PAT decoding. Native browser consent/callback itself is not exercised by the fixture browser.
- Actual Keychain tests use UUID-owned fake credentials only: add/update/read/delete a temporary item, preserve OAuth refresh metadata, and invoke the app's actual helper through `git credential fill`. The OAuth helper returns the access token (including the GitLab oauth2 username path) and no refresh token. No personal token was read or changed for testing.
- The initial full App run had two assertions fail in the existing FSEvents external-edit case. A file edit could occur while the watcher started, leaving its first change/selection unobserved. Monitoring now requests an initial reconciliation read after successful startup. The same case and the final complete App run pass. Original failure output is retained in the run record; it was not waived by increasing the wait.
- A first compile caught a Swift 6 isolation issue in the fixture transport's Any dictionaries. The fixture now converts them to Sendable response values before handing them to the actor. Native browser generation guards were compiled in the final staged build; live provider/browser lifecycle acceptance remains pending.
- `./script/build_and_run.sh --verify` built and staged the app, verified code signing and checked suppressed/native startup. [Background result](evidence/oauth-2026-10-26/background-verification.json), [native result](evidence/oauth-2026-10-26/native-startup-verification.json) show no activation and zero visible GitPico windows. [Bundle metadata](evidence/oauth-2026-10-26/build-metadata.json) records 0.01, the date build, minimum 26.0 and the gitpico URL scheme. `git diff --check` passed.

## Visual checks

Hidden native windows captured both appearances, including the lower Form area after scrolling. No browser was launched by capture fixtures and no real account was used in the displayed metadata. Buttons, labels, account method/reconnect actions and retained PAT/diagnostic controls were inspected:

- [Authentication light](evidence/oauth-2026-10-26/authentication-light.png), [dark](evidence/oauth-2026-10-26/authentication-dark.png).
- [Lower form light](evidence/oauth-2026-10-26/authentication-lower-light.png), [dark](evidence/oauth-2026-10-26/authentication-lower-dark.png).

## Remaining acceptance

The user has not yet approved either provider's repository grant inside the staged GitPico app. Real browser consent/callback, hosted account Token renewal, SSO/organization restrictions, actual private-repository Git read/write permissions, foreground keyboard/mouse/VoiceOver and macOS 26 execution remain unverified. Registration and an accepted device challenge do not prove those paths. No foreground GitPico test was run; Chrome was used only for the explicitly requested app registrations, with login completed by the user. Release signing/notarization and stable Keychain trust across distributed app upgrades remain separate release work.

## Reproduction and primary references

Run the shared scheme with `xcodebuild test -project GitPico.xcodeproj -scheme GitPico -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO`. Xcode opt-in environment variables use `TEST_RUNNER_` prefixes:

- `GITPICO_VERIFY_KEYCHAIN_HELPER=1` enables temporary fake Keychain/helper checks.
- `GITPICO_CAPTURE_MATURITY_PANELS=1`, `GITPICO_CAPTURE_OAUTH_PANELS=1`, `GITPICO_MATURITY_CAPTURE_OUTPUT=<absolute folder>` enable suppressed appearance/scroll captures.
- `GITPICO_VERIFY_OAUTH_REGISTRATION=1`, `GITPICO_OAUTH_REGISTRATION_REPORT=<absolute JSON file>` request one real GitHub challenge, without approving it. This is opt-in and is not necessary for ordinary regression.

Individual Swift Testing filters include parentheses. Local verbose logs remain in `.build/oauth-*.log`; committed evidence omits unrelated OS diagnostic noise and all tokens/codes/verifiers.

Provider contracts were checked against [GitHub OAuth/device authorization](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps) and [GitLab PKCE/refresh/Git authentication](https://docs.gitlab.com/api/oauth2/). The implementation does not assume GitHub's web-code flow can omit its client secret; it uses Device Flow instead.
